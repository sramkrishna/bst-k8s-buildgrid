# BuildStream client image for in-cluster Jobs.
# Includes everything we discovered gnome-build-meta needs (see the journal):
# dulwich, buildstream-plugins*, requests, tomlkit, lzip binary, git, make.
# fedora:41 caused reproducible buildbox-casd SIGSEGVs; fedora:latest
# (currently fedora:44, matching brigid's host) works. Suspect glibc
# version drift interacting with the bundled casd binary.
FROM registry.fedoraproject.org/fedora:latest

RUN dnf install -y --setopt=install_weak_deps=False \
      python3 python3-pip pipx \
      git openssh-clients ca-certificates \
      make gcc openssl gnupg2 \
      lzip xz zstd bzip2 gzip tar cpio rsync file \
      bubblewrap fuse3 \
      gettext \
      patch diffutils quilt \
      ostree \
      which findutils \
      xz zstd \
      /usr/bin/time \
 && dnf clean all
# Full list of host tools bst source plugins can require (found via
# `grep get_host_tool` in buildstream + buildstream_plugins +
# buildstream_plugins_community):
#     bazel, bzr, cargo, git, lzip, ostree, patch, quilt
# git/lzip/ostree/patch/quilt covered above.
# bzr = breezy in modern Fedora (deprecated ecosystem — skip).
# bazel/cargo = huge and unlikely for gnome-build-meta client side
# (actual compilers run in the worker sandbox). Add here later if a
# concrete element needs them.

# BuildStream 2.x via pipx (matches host install on brigid).
RUN pipx install --python python3 BuildStream && \
    pipx inject BuildStream \
        dulwich buildstream-plugins buildstream-plugins-community \
        requests tomlkit

ENV PATH="/root/.local/bin:${PATH}" \
    XDG_CACHE_HOME=/cache \
    XDG_CONFIG_HOME=/config

# Force casd to use HardLinkStager instead of FUSE. FUSE inside an
# unprivileged pod dies with "child process exit code 2" — the pod
# doesn't have /dev/fuse plumbing. Removing the binary makes casd's
# stager discovery fall through cleanly.
RUN find /root/.local/share/pipx/venvs -name buildbox-fuse -delete && \
    ! bst --version 2>&1 | grep -qi 'no such'  # sanity

# Sanity — fail the build if bst can't run
RUN bst --version

WORKDIR /work
CMD ["/bin/bash"]
