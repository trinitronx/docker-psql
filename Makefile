.PHONY: all list package ship container-ship deploy container-deploy secrets build-inception-container clean

#REPO := docker-registry.efp.returnpath.net/mentat
REPO := returnpath/psql
REV := $(shell TZ=UTC date +'%Y%m%dT%H%M%S')-$(shell git rev-parse --short HEAD)
BUILD_TOOLS := trinitronx/build-tools:ubuntu-1404

# Load both ~/.aws and ENV variables for awscli calls so this will work
# with the full aws cli credential detection system (and allows us to run
# on local machines with ~/.aws or jenkins with ENV variables).
DOCKER_AWS_CREDENTIALS := -v ~/.aws:/root/.aws
ifdef AWS_ACCESS_KEY_ID
	DOCKER_AWS_CREDENTIALS += -e AWS_ACCESS_KEY_ID=$(AWS_ACCESS_KEY_ID)
endif
ifdef AWS_SECRET_ACCESS_KEY
	DOCKER_AWS_CREDENTIALS += -e AWS_SECRET_ACCESS_KEY=$(AWS_SECRET_ACCESS_KEY)
endif

## Platform Detection (for command line arg portability)
ifeq ($(OS),Windows_NT)
    define BASE64_FLAGS
    endef
else
    UNAME_S := $(shell uname -s)
    ifeq ($(UNAME_S),Linux)
        define BASE64_FLAGS
          -w 0
        endef
    endif
    ifeq ($(UNAME_S),Darwin)
        define BASE64_FLAGS
        endef
    endif
endif

list:
	@$(MAKE) -pRrq -f $(lastword $(MAKEFILE_LIST)) : 2>/dev/null | awk -v RS= -F: '/^# File/,/^# Finished Make data base/ {if ($$1 !~ "^[#.]") {print $$1}}' | sort | egrep -v -e '^[^[:alnum:]]' -e '^$@$$' | xargs


.docker_config.json:
	`docker run --rm $(DOCKER_AWS_CREDENTIALS) returnpath/awscli ecr get-login`
	[ -d .docker ] || mkdir .docker
	cp ~/.docker/config.json .docker/config.json

# build-inception-container: .docker_config.json
# 	docker pull $(BUILD_TOOLS)
# 	docker build -f build/Dockerfile.make -t "$(REPO):build" .
# 	docker push "$(REPO):build"

package: $(shell git ls-files --others --cached --deleted --modified --exclude-standard | grep -v '$(DEPLOYMENT_YML)' )
	docker build -t "$(REPO):$(REV)" .

container-package: build-inception-container $(shell git ls-files --others --cached --deleted --modified --exclude-standard | grep -v '$(DEPLOYMENT_YML)' )
	docker build -f build/Dockerfile.make -t "$(REPO):build-$(REV)" .
	docker run --rm $(DOCKER_AWS_CREDENTIALS)             \
             -e KUBECTL_FLAGS=$(KUBECTL_FLAGS)            \
             --net=host                                   \
             -v /var/run/docker.sock:/var/run/docker.sock \
             -v $(PWD):/root/                             \
             "$(REPO):build-$(REV)"                       \
             make package
	docker rmi "$(REPO):build-$(REV)"

ship: package .docker_config.json
	docker tag $(REPO):$(REV) $(REPO):latest
	docker push $(REPO):$(REV)
	docker push $(REPO):latest

container-ship: .docker_config.json
	docker build -f build/Dockerfile.make -t "$(REPO):build-$(REV)" .
	docker run --rm $(DOCKER_AWS_CREDENTIALS)             \
             -v /var/run/docker.sock:/var/run/docker.sock \
             -v $(PWD):/root/                             \
             "$(REPO):build-$(REV)"                       \
             make ship
	docker rmi "$(REPO):build-$(REV)"

$(DEPLOYMENT_YML): build/deployment-template.yml package
	sed 's|<DOCKER_IMAGE>|$(REPO):$(REV)|' build/deployment-template.yml > $(DEPLOYMENT_YML)

deploy: ship $(DEPLOYMENT_YML) .docker_config.json
	kubectl $(KUBECTL_FLAGS) apply -f build/deployment.yml -f build/service.yml

container-deploy: clean .docker_config.json
	docker build -f build/Dockerfile.make -t "$(REPO):build-$(REV)" .
	docker run --rm $(DOCKER_AWS_CREDENTIALS)               \
             -e KUBECTL_FLAGS=$(KUBECTL_FLAGS)            \
             --net=host                                   \
             -v /var/run/docker.sock:/var/run/docker.sock \
             -v $(PWD):/root/                             \
             "$(REPO):build-$(REV)"                       \
             make deploy
	docker rmi "$(REPO):build-$(REV)"

secrets:
	@echo "Installing secrets into Kubernetes Cluster"
	@stty -echo
	@echo $(pgpass)$(shell bash -c 'echo "LastPass Master Password: " > /dev/stderr; docker run --rm -ti  -e LPASS_DISABLE_PINENTRY=1 -e LPASS_ASKPASS='quiet-askpass' -v $(HOME)/.lpass:/root/.lpass returnpath/lpass:0.8.1 show --password "EFP RDS Shared"')                                                      | \
	base64 $(BASE64_FLAGS)                                           | \
	awk '{ system("                                                    \
	 	sed s/\\<SECRET_CONTENT\\>/"$$1"/ $(SECRET_TEMPLATE) | \
	 	kubectl apply -f -                                             \
	")}'
	@stty echo

kube-proxy:
	@echo "Running kubectl proxy to connect to Kubernetes Cluster from build container"
	kubectl proxy --port=8080 --server="$(KUBERNETES_MASTER)" &

container-secrets: clean .docker_config.json
	docker build -f build/Dockerfile.make -t "$(REPO):build-$(REV)" .
	docker run --rm -it $(DOCKER_AWS_CREDENTIALS)             \
             -e KUBECTL_FLAGS=$(KUBECTL_FLAGS)                \
             --net=host                                       \
             -v /var/run/docker.sock:/var/run/docker.sock     \
             -v $(HOME)/.lpass:/root/.lpass                   \
             -v $(PWD):/root/                                 \
             "$(REPO):build-$(REV)"                           \
             make kube-proxy secrets
	docker rmi "$(REPO):build-$(REV)"

clean:
	rm -f .docker_config.json
	rm -f $(DEPLOYMENT_YML)
