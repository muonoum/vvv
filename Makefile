watch := watchexec --clear --quiet --restart --stop-signal INT --stop-timeout 150ms --watch .restart

.PHONY: dev
dev:
	$(watch) make run --no-print-directory

.PHONY: dev-env
dev-env:
	test -n "$(env)"
	$(watch) "source $(env) && make run --no-print-directory"

.PHONY: run
run: frontend
	gleam run

.PHONY: frontend
frontend:
	mkdir -p priv/static
	cp assets/favicon.ico priv/static/favicon.ico
	esbuild --bundle --format=esm --log-level=error --loader:.ttf=file --loader:.woff2=file \
	--external:tailwindcss --outdir=priv/static assets/app.css
	tailwindcss --minify --input priv/static/app.css --output priv/static/build.css
	mv priv/static/build.css priv/static/app.css

.restart:
	touch .restart

.PHONY: commit
commit: commit_message ?= $(shell git diff --name-only --cached | rev | cut -d/ -f 1,2 | rev | xargs)
commit:
	test -n "$(commit_message)"
	git commit -m "$(commit_message)"

.PHONY: push
push: commit
	git push
