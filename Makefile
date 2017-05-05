up: run
deploy: run
run:
	docker-compose build --pull && \
	docker-compose up -d --remove-orphans

build:
	docker-compose build --pull

stop:
	docker-compose stop

down:
	docker-compose down --remove-orphans

runshell:
	docker-compose run --service-ports app julia -L shell.jl

shell:
	docker-compose exec app julia -L shell.jl

log: logs
logs:
	docker-compose logs -f
