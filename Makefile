CROSSPLANE ?= crossplane
PYTHON ?= python3
PACKAGE ?= _output/configuration-caas.xpkg

.PHONY: generate check test build
generate:
	$(PYTHON) scripts/generate_composition.py

check:
	$(PYTHON) scripts/generate_composition.py --check
	yamllint apis examples

test: check
	CROSSPLANE=$(CROSSPLANE) $(PYTHON) -m unittest discover -s tests -v

build: check
	mkdir -p _output
	$(CROSSPLANE) xpkg build --package-root=apis --examples-root=examples --package-file=$(PACKAGE)
