watch := watchexec --clear --quiet --restart --stop-signal INT --stop-timeout 150ms --watch .restart

.PHONY: dev
dev:
	HTTP_PORT=1980 \
	SECRET_KEY_BASE=VPJ4WamuGU6kGoQ3UfXlozI0yGbZ06dVFTzpE6ztdWKjiHXEpo \
	make watch

.PHONY: run
run: frontend
	gleam run

.PHONY: watch
watch: .restart
	$(watch) make run --no-print-directory

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
