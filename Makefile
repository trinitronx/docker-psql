.PHONY: all list package ship container-ship deploy container-deploy secrets build-inception-container .check-docker-credentials-expired clean

#REPO := docker-registry.efp.returnpath.net/mentat
REPO := returnpath/psql
REV := $(shell TZ=UTC date +'%Y%m%dT%H%M%S')-$(shell git rev-parse --short HEAD)
BUILD_TOOLS := trinitronx/build-tools:ubuntu-1404

# Load both ~/.aws and ENV variables for awscli calls so this will work
# with the full aws cli credential detection system (and allows us to run
# on local machines with ~/.aws or jenkins with ENV variables).
DOCKER_AWS_CREDENTIALS := -v $(HOME)/.aws:/root/.aws
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

.check-docker-credentials-expired:
	@#Note: This target is defined as an "order-only" prerequisite type so as to preserve conditional execution of .docker/config.json target
	@#See: https://www.gnu.org/software/make/manual/html_node/Prerequisite-Types.html#Prerequisite-Types
	@if [ ! -d .docker ]; then mkdir .docker ; fi
	@#Always remove our local .docker/config.json if it is expired & older than 12 hrs
	#Checking if .docker/config.json Credentials are expired & re-run make if older than 12 hrs
	if [ -e .docker/config.json ]; then  find .docker/config.json -mmin +720 -exec bash -c 'rm -f "{}"; $(MAKE) .docker/config.json' \; ; fi

.docker/config.json: | .check-docker-credentials-expired
	@# Shell will suppress the output the ecr-login task to avoid logging the creds
	@# Comment that will get output minus creds so we know what is going on
	#`docker run --rm $$(DOCKER_AWS_CREDENTIALS) returnpath/awscli ecr get-login`
	@`docker run --rm $(DOCKER_AWS_CREDENTIALS) returnpath/awscli ecr get-login`
	cp ~/.docker/config.json .docker/config.json

build/Dockerfile.make.onbuild:
	echo 'FROM $(REPO):build\n\nRUN [ -e /src/jobs ] || mkdir /src/jobs' > build/Dockerfile.make.onbuild

build-inception-container: .docker/config.json
	docker pull $(BUILD_TOOLS)
	docker build -f build/Dockerfile.make -t "$(REPO):build" .
	docker --config=.docker/ push "$(REPO):build"

package: $(shell git ls-files --others --cached --deleted --modified --exclude-standard | grep -v '$(DEPLOYMENT_YML)' )
	docker build -t "$(REPO):$(REV)" .

container-package: build-inception-container build/Dockerfile.make.onbuild $(shell git ls-files --others --cached --deleted --modified --exclude-standard | grep -v '$(DEPLOYMENT_YML)' )
	docker build -f build/Dockerfile.make.onbuild -t "$(REPO):build-$(REV)" .
	@# Suppress the output of any tasks including DOCKER_AWS_CREDENTIALS to avoid logging the creds
	@# Comment that will get output minus creds so we know what is going on
	#docker run --rm $$(DOCKER_AWS_CREDENTIALS) -v /var/run/docker.sock:/var/run/docker.sock "$(REPO):build-$(REV)" make package
	@docker run --rm $(DOCKER_AWS_CREDENTIALS)            \
             -v /var/run/docker.sock:/var/run/docker.sock \
             "$(REPO):build-$(REV)"                       \
             make package
	docker rmi "$(REPO):build-$(REV)"

ship: package .docker/config.json
	docker tag $(REPO):$(REV) $(REPO):latest
	docker --config=.docker/ push $(REPO):$(REV)
	docker --config=.docker/ push $(REPO):latest

container-ship: build-inception-container build/Dockerfile.make.onbuild .docker/config.json
	docker build -f build/Dockerfile.make.onbuild -t "$(REPO):build-$(REV)" .
	@# Comment that will get output minus creds so we know what is going on
	#docker run --rm $$(DOCKER_AWS_CREDENTIALS) -v /var/run/docker.sock:/var/run/docker.sock "$(REPO):build-$(REV)" make ship
	@docker run --rm $(DOCKER_AWS_CREDENTIALS)            \
             -v /var/run/docker.sock:/var/run/docker.sock \
             "$(REPO):build-$(REV)"                       \
             "make ship"
	docker rmi "$(REPO):build-$(REV)"

container-debug-docker: build-inception-container build/Dockerfile.make.onbuild .docker/config.json
	docker build -f build/Dockerfile.make.onbuild -t "$(REPO):build-$(REV)" .
	@# Comment that will get output minus creds so we know what is going on
	#docker run --rm $$(DOCKER_AWS_CREDENTIALS) -v /var/run/docker.sock:/var/run/docker.sock "$(REPO):build-$(REV)" curl https://raw.githubusercontent.com/docker/docker/master/contrib/check-config.sh | /bin/bash
	@docker run --rm $(DOCKER_AWS_CREDENTIALS)            \
             -v /var/run/docker.sock:/var/run/docker.sock \
             "$(REPO):build-$(REV)"                       \
             "curl   https://raw.githubusercontent.com/docker/docker/master/contrib/check-config.sh | /bin/bash"
	docker rmi "$(REPO):build-$(REV)"

$(DEPLOYMENT_YML): build/deployment-template.yml package
	sed 's|<DOCKER_IMAGE>|$(REPO):$(REV)|' build/deployment-template.yml > $(DEPLOYMENT_YML)

deploy: ship $(DEPLOYMENT_YML) .docker_config.json
	kubectl $(KUBECTL_FLAGS) apply -f build/deployment.yml -f build/service.yml

deploy: ship $(DEPLOYMENT_YML) .docker/config.json configmap
	kubectl $(KUBECTL_FLAGS) apply -f $(DEPLOYMENT_YML)

container-deploy: clean .docker/config.json build/Dockerfile.make.onbuild
	docker build -f build/Dockerfile.make.onbuild -t "$(REPO):build-$(REV)" .
	@# Comment that will get output minus creds so we know what is going on
	#docker run --rm $$(DOCKER_AWS_CREDENTIALS) -v /var/run/docker.sock:/var/run/docker.sock  -e KUBECTL_FLAGS="$(KUBECTL_FLAGS)" --net=host "$(REPO):build-$(REV)" make deploy
	@docker run --rm $(DOCKER_AWS_CREDENTIALS)        \
             -e KUBECTL_FLAGS="$(KUBECTL_FLAGS)"          \
             --net=host                                   \
             -v /var/run/docker.sock:/var/run/docker.sock \
             "$(REPO):build-$(REV)"                       \
             make deploy
	docker rmi "$(REPO):build-$(REV)"

secrets:
	@echo "Installing secrets into Kubernetes Cluster"
	@stty -echo
	@docker run --rm -i                                                                                    \
	           -e LPASS_DISABLE_PINENTRY=1                                                                 \
	           -v ~/.lpass:/root/.lpass returnpath/lpass:0.8.1                                             \
	           show --password "EFP RDS Shared"                                                          | \
	tr -d '\r\n' | base64 $(BASE64_FLAGS)                                                                | \
	awk '{ system("                                                                                        \
	 	sed -e s/\\<PASSWORD_FROM_LASTPASS\\>/"$$1"/                                                   \
	 	    -e s/\\<PGUSER\\>/$(shell bash -c 'echo -n $(PGUSER) | base64 $(BASE64_FLAGS)')/           \
	 	    -e s/\\<PGDATABASE\\>/$(shell bash -c 'echo -n $(PGDATABASE) | base64 $(BASE64_FLAGS)')/   \
	 	    -e s/\\<PGHOST\\>/$(shell bash -c 'echo -n $(PGHOST) | base64 $(BASE64_FLAGS)')/           \
	 	    -e s/\\<PGPORT\\>/$(shell bash -c 'echo -n $(PGPORT) | base64 $(BASE64_FLAGS)')/           \
	 	    $(SECRET_TEMPLATE)                                                                       | \
	 	kubectl apply -f -                                                                             \
	")}'
	@stty echo

container-secrets: clean .docker/config.json build/Dockerfile.make.onbuild
	docker build -f build/Dockerfile.make.onbuild -t "$(REPO):build-$(REV)" .
	@# Comment that will get output minus creds so we know what is going on
	#docker run --rm -it $$(DOCKER_AWS_CREDENTIALS) -e KUBECTL_FLAGS="$(KUBECTL_FLAGS)" --net=host -v /var/run/docker.sock:/var/run/docker.sock -v $(HOME)/.lpass:/root/.lpass -v $(PWD):/root/  "$(REPO):build-$(REV)" make secrets
	@docker run --rm -it $(DOCKER_AWS_CREDENTIALS)    \
             -e KUBECTL_FLAGS="$(KUBECTL_FLAGS)"          \
             --net=host                                   \
             -v /var/run/docker.sock:/var/run/docker.sock \
             -v $(HOME)/.lpass:/root/.lpass               \
             -v $(PWD):/root/                             \
             "$(REPO):build-$(REV)"                       \
             make secrets
	docker rmi "$(REPO):build-$(REV)"

clean:
	rm -f .docker/config.json
	rm -f build/Dockerfile.make.onbuild
	rm -f $(DEPLOYMENT_YML)
