SHELL = /bin/sh
PLATFORM := $(shell uname | tr A-Z a-z)
ARCHITECTURE := $(shell uname -m)
ifeq ($(ARCHITECTURE),x86_64)
	ARCHITECTURE=amd64
endif

ifeq ($(ARCHITECTURE),aarch64)
	ARCHITECTURE=arm64
endif

.DEFAULT_GOAL := all

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

all::crd ## Default goal. Generates bundle manifests
all::rbac
all::deployment
all::olm-manifests

.PHONY: all crd rbac deployment olm-manifests clean

OLM_DIR = $(CURDIR)/olm/manifests
$(OLM_DIR) :
	mkdir -pv $@

crd: $(OLM_DIR) ## Generate CRD manifest
	kustomize build config/crd > $(OLM_DIR)/rabbitmq.com_rabbitmqcluster.yaml

rbac: ## Extract RBAC rules to a temporary file
	mkdir -p tmp/
	yq '{"rules": .rules}' config/rbac/role.yaml > tmp/role-rules.yaml

QUAY_IO_OPERATOR_IMAGE ?= quay.io/rabbitmqoperator/cluster-operator:latest
deployment: ## Extract deployment spec. Customise using QUAY_IO_OPERATOR_IMAGE
	mkdir -p tmp/
	kustomize build config/installation/ | \
		ytt -f- -f config/ytt/overlay-manager-image.yaml \
			--data-value operator_image=$(QUAY_IO_OPERATOR_IMAGE) \
			-f olm/templates/cluster-operator-namespace-scope-overlay.yml \
		> tmp/cluster-operator.yml
	yq '{"spec": .spec}' tmp/cluster-operator.yml > tmp/spec.yaml

BUNDLE_CREATED_AT ?= $(shell date +'%Y-%m-%dT%H:%M:%S')
BUNDLE_VERSION ?= 0.0.0
olm-manifests: $(OLM_DIR) ## Render bundle manifests. Customise version using BUNDLE_VERSION and BUNDLE_CREATED_AT
	ytt -f $(CURDIR)/olm/templates/cluster-service-version-generator-openshift.yml \
		--data-values-file $(CURDIR)/tmp/role-rules.yaml \
		--data-values-file $(CURDIR)/tmp/spec.yaml \
		--data-value name="rabbitmq-cluster-operator" \
		--data-value createdAt="$(BUNDLE_CREATED_AT)" \
		--data-value image="$(QUAY_IO_OPERATOR_IMAGE)" \
		--data-value version="$(BUNDLE_VERSION)" \
		--data-value replaces="$(BUNDLE_REPLACES)" \
		> $(OLM_DIR)/rabbitmq-cluster-operator.clusterserviceversion.yaml

clean:
	rm -f -v $(CURDIR)/olm/manifests/*.y*ml

###########
## Build ##
###########

CONTAINER ?= docker
REGISTRY ?= quay.io
IMAGE ?= rabbitmqoperator/rabbitmq-for-kubernetes-olm-cluster-operator:latest
BUNDLE_IMAGE = $(REGISTRY)/$(IMAGE)

.PHONY: docker-build docker-push
docker-build: ## Build bundle container. Customise using REGISTRY and IMAGE
	$(CONTAINER) build -t $(BUNDLE_IMAGE) -f $(CURDIR)/olm/bundle.Dockerfile $(CURDIR)/olm

docker-push: ## Push bundle container. Customise using REGISTRY and IMAGE
	$(CONTAINER) push $(BUNDLE_IMAGE)

#############
## Catalog ##
#############
# This is used in tests

CATALOG_DIR = $(CURDIR)/olm/catalog
$(CATALOG_DIR):
	mkdir -p $@

.PHONY: catalog-*
catalog-replace-bundle: $(CATALOG_DIR) ## Generate catalog manifest. Customise using BUNDLE_IMAGE and BUNDLE_VERSION
	ytt -f $(CURDIR)/olm/templates/catalog-template.yaml \
		--data-value name="rabbitmq-cluster-operator" \
		--data-value image="$(BUNDLE_IMAGE)" \
		--data-value version="$(BUNDLE_VERSION)" \
	> $(CATALOG_DIR)/catalog.yaml

CATALOG_IMAGE ?= rabbitmqoperator/test-catalog:latest
catalog-build: ## Build catalog image. Customise using REGISTRY and CATALOG_IMAGE
	$(CONTAINER) build -t $(REGISTRY)/$(CATALOG_IMAGE) --label "quay.expires-after=48h" -f $(CURDIR)/olm/catalog.Dockerfile ./olm

catalog-push: ## Push catalog image. Customise using REGISTRY and CATALOG_IMAGE
	$(CONTAINER) push $(REGISTRY)/$(CATALOG_IMAGE)

catalog-deploy: ## Deploy a catalog source to an existing k8s
	kubectl apply -f $(CURDIR)/olm/assets/operator-group.yaml
	ytt -f $(CURDIR)/olm/assets/catalog-source.yaml --data-value image="$(REGISTRY)/$(CATALOG_IMAGE)" | kubectl apply -f-
	kubectl apply -f $(CURDIR)/olm/assets/subscription.yaml

catalog-undeploy: ## Delete all catalog assets from k8s
	kubectl delete -f $(CURDIR)/olm/assets/subscription.yaml --ignore-not-found
	kubectl delete -f $(CURDIR)/olm/manifests/ --ignore-not-found
	kubectl delete -f $(CURDIR)/olm/assets/operator-group.yaml --ignore-not-found
	ytt -f $(CURDIR)/olm/assets/catalog-source.yaml --data-value image="$(REGISTRY)/$(CATALOG_IMAGE)" | kubectl delete -f- --ignore-not-found

catalog-clean: ## Delete manifest files for catalog
	rm -v -f $(CURDIR)/olm/catalog/*.y*ml

catalog-all::catalog-replace-bundle
catalog-all::catalog-build
catalog-all::catalog-push
catalog-all::catalog-deploy
