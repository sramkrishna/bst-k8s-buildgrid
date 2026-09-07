kind: import

description: Tiny Alpine minirootfs — provides /bin/sh for the sandbox.

sources:
- kind: tar
  url: https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-minirootfs-3.20.0-x86_64.tar.gz
  # `bst source track base.bst` will fill this in on first use.
