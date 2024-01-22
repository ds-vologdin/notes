SHELL:=bash

.PHONY: build
build:
	mkdocs build

.PHONY: deploy
deploy:
	mkdocs gh-deploy

.PHONY: serve
serve:
	mkdocs serve

.PHONY: venv
venv:
	python3 -m venv ./venv
	( \
		source ./venv/bin/activate; \
		pip install -r requirements.txt; \
	)
	@echo "now you can use: 'source ./venv/bin/activate'"
