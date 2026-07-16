FROM registry.fedoraproject.org/fedora:44

RUN dnf install -y swift-lang gtk4-devel libadwaita-devel git \
    && dnf clean all
