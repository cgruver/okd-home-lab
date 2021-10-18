FROM registry.access.redhat.com/ubi8/ubi-minimal:8.4
ARG MAVEN_VERSION=3.8.3
ARG BASE_URL=https://apache.osuosl.org/maven/maven-3/${MAVEN_VERSION}/binaries
ARG JAVA_PACKAGE=java-11-openjdk-headless
ARG MANDREL_VERSION=21.2.0.1-Final
ARG USER_HOME_DIR="/maven"
ARG WORK_DIR="/workspace"
ARG GRAALVM_DIR=/opt/mandral
ENV LANG='en_US.UTF-8' LANGUAGE='en_US:en' LC_ALL='en_US.UTF-8'
RUN microdnf install glibc-devel zlib-devel gcc libffi-devel libstdc++-devel gcc-c++ glibc-langpack-en openssl curl ca-certificates git tar which ${JAVA_PACKAGE} shadow-utils \
    && microdnf update \
    && microdnf clean all \
    && mkdir -p ${USER_HOME_DIR} \
    && chown 1001 ${USER_HOME_DIR} \
    && chmod "g+rwX" ${USER_HOME_DIR} \
    && chown 1001:root ${USER_HOME_DIR} \
    && mkdir -p ${WORK_DIR} \
    && chown 1001 ${WORK_DIR} \
    && chmod "g+rwX" ${WORK_DIR} \
    && chown 1001:root ${WORK_DIR} \
    && echo "securerandom.source=file:/dev/urandom" >> /etc/alternatives/jre/lib/security/java.security \
    && mkdir -p /usr/share/maven /usr/share/maven/ref \
    && curl -fsSL -o /tmp/apache-maven.tar.gz ${BASE_URL}/apache-maven-${MAVEN_VERSION}-bin.tar.gz \
    && tar -xzf /tmp/apache-maven.tar.gz -C /usr/share/maven --strip-components=1 \
    && rm -f /tmp/apache-maven.tar.gz \
    && ln -s /usr/share/maven/bin/mvn /usr/bin/mvn \
    && mkdir -p ${GRAALVM_DIR} \
    && curl -fsSL -o /tmp/mandrel-java11-linux-amd64-${MANDREL_VERSION}.tar.gz https://github.com/graalvm/mandrel/releases/download/mandrel-${MANDREL_VERSION}/mandrel-java11-linux-amd64-${MANDREL_VERSION}.tar.gz \
    && tar xzf /tmp/mandrel-java11-linux-amd64-${MANDREL_VERSION}.tar.gz -C ${GRAALVM_DIR} --strip-components=1
ENV MAVEN_HOME=/usr/share/maven
ENV MAVEN_CONFIG="${USER_HOME_DIR}/.m2"
ENV GRAALVM_HOME=${GRAALVM_DIR}

VOLUME ${WORK_DIR}