FROM koalaman/shellcheck-alpine:latest AS shellcheck
COPY ./assets /assets
WORKDIR /assets
RUN /bin/shellcheck --shell=bash check in out *.sh

FROM debian:jessie as builder
RUN apt-get -y update && apt-get -y install curl unzip
ARG SONAR_SCANNER_DOWNLOAD_URL="https://sonarsource.bintray.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-3.1.0.1141-linux.zip"
RUN curl -s -L "${SONAR_SCANNER_DOWNLOAD_URL}" > "/tmp/sonar-scanner-cli-3.1.0.1141-linux.zip" \
&& unzip -qq "/tmp/sonar-scanner-cli-3.1.0.1141-linux.zip" -d "/data" \
&& mv "/data/sonar-scanner-3.1.0.1141-linux" "/data/sonar-scanner" \
&& rm -f "/tmp/sonar-scanner-cli-3.1.0.1141-linux.zip"
ARG MAVEN_DOWNLOAD_URL="http://ftp-stud.hs-esslingen.de/pub/Mirrors/ftp.apache.org/dist/maven/maven-3/3.5.2/binaries/apache-maven-3.5.2-bin.zip"
RUN curl -s -L "${MAVEN_DOWNLOAD_URL}" > "/tmp/apache-maven-3.5.2-bin.zip" \
&& unzip -qq "/tmp/apache-maven-3.5.2-bin.zip" -d "/data" \
&& mv "/data/apache-maven-3.5.2" "/data/apache-maven" \
&& rm -f "/tmp/apache-maven-3.5.2-bin.zip"

FROM openjdk:8u151-alpine
RUN apk -f -q update \
&& apk -f -q add bash curl gawk git jq nodejs

# https://github.com/concourse/concourse/issues/2042
RUN unlink  $JAVA_HOME/jre/lib/security/cacerts && \
cp "/etc/ssl/certs/java/cacerts" "${JAVA_HOME}/jre/lib/security/cacerts"

COPY --from=builder "/data/sonar-scanner" "/opt/sonar-scanner"
RUN rm -Rf "/opt/sonar-scanner/jre" \
&& ln -sf "/usr" "/opt/sonar-scanner/jre" \
&& ln -sf "/opt/sonar-scanner/bin/sonar-scanner" "/usr/local/bin/sonar-scanner" \
&& ln -sf "/opt/sonar-scanner/bin/sonar-scanner-debug" "/usr/local/bin/sonar-scanner-debug"
COPY --from=builder "/data/apache-maven" "/opt/apache-maven"
RUN ln -sf "/opt/apache-maven/bin/mvn" "/usr/local/bin/mvn" \
&& ln -sf "/opt/apache-maven/bin/mvnDebug" "/usr/local/bin/mvnDebug"
ENV M2_HOME="/opt/apache-maven"

RUN mvn -q org.apache.maven.plugins:maven-dependency-plugin:3.0.2:get \
-DrepoUrl="https://repo.maven.apache.org/maven2/" \
-Dartifact="org.sonarsource.scanner.maven:sonar-maven-plugin:3.4.0.905:jar"

RUN apk add --no-cache ca-certificates

ENV GOLANG_VERSION 1.10.1

# make-sure-R0-is-zero-before-main-on-ppc64le.patch: https://github.com/golang/go/commit/9aea0e89b6df032c29d0add8d69ba2c95f1106d9 (Go 1.9)
#COPY *.patch /go-alpine-patches/

RUN set -eux; \
	apk add --no-cache --virtual .build-deps \
		bash \
		gcc \
		musl-dev \
		openssl \
		go \
	; \
	export \
# set GOROOT_BOOTSTRAP such that we can actually build Go
		GOROOT_BOOTSTRAP="$(go env GOROOT)" \
# ... and set "cross-building" related vars to the installed system's values so that we create a build targeting the proper arch
# (for example, if our build host is GOARCH=amd64, but our build env/image is GOARCH=386, our build needs GOARCH=386)
		GOOS="$(go env GOOS)" \
		GOARCH="$(go env GOARCH)" \
		GOHOSTOS="$(go env GOHOSTOS)" \
		GOHOSTARCH="$(go env GOHOSTARCH)" \
	; \
# also explicitly set GO386 and GOARM if appropriate
# https://github.com/docker-library/golang/issues/184
	apkArch="$(apk --print-arch)"; \
	case "$apkArch" in \
		armhf) export GOARM='6' ;; \
		x86) export GO386='387' ;; \
	esac; \
	\
	wget -O go.tgz "https://golang.org/dl/go$GOLANG_VERSION.src.tar.gz"; \
	echo '589449ff6c3ccbff1d391d4e7ab5bb5d5643a5a41a04c99315e55c16bbf73ddc *go.tgz' | sha256sum -c -; \
	tar -C /usr/local -xzf go.tgz; \
	rm go.tgz; \
	\
	cd /usr/local/go/src; \
	for p in /go-alpine-patches/*.patch; do \
		[ -f "$p" ] || continue; \
		patch -p2 -i "$p"; \
	done; \
	./make.bash; \
	\
	rm -rf /go-alpine-patches; \
	apk del .build-deps; \
	\
	export PATH="/usr/local/go/bin:$PATH"; \
	go version




ENV PATH="/usr/local/bin:/usr/bin:/bin"

COPY ./assets/* /opt/resource/

ENV GOPATH /go
ENV PATH $GOPATH/bin:/usr/local/go/bin:$PATH

RUN mkdir -p "$GOPATH/src" "$GOPATH/bin" && chmod -R 777 "$GOPATH"
WORKDIR $GOPATH