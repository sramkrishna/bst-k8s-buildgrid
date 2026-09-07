kind: manual

depends:
- base.bst

config:
  install-commands:
  - "echo hello > %{install-root}/hello.txt"
