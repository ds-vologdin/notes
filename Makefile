.PHONY: build
build:
	mkdocs build

.PHONY: deploy
deploy:
	mkdocs gh-deploy

.PHONY: serve
serve:
	mkdocs serve
