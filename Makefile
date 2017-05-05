up: run
deploy: run
run:
	docker-compose build --pull && \
	docker-compose up -d --remove-orphans

build:
	docker-compose build --pull

down: stop
stop:
	docker-compose down --remove-orphans

shell:
	docker-compose run --service-ports app julia -L shell.jl

log: logs
logs:
	docker-compose logs -f
