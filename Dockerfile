FROM julia

RUN apt update && apt install -y unzip build-essential libmysqlclient-dev
# Make sure we track HTTP.jl closely
ADD https://api.github.com/repos/JuliaWeb/HTTP.jl/git/refs/heads/master /HTTP.jl.json
RUN julia -e 'Pkg.clone("HTTP"); Pkg.add("GitHub"); Pkg.clone("MySQL"); Pkg.build();'
RUN julia -e 'using GitHub; using HttpCommon; using MySQL; using HTTP'


WORKDIR /app
COPY src /app/src
COPY test /app/test
COPY run_server.jl /app/run_server.jl
CMD ["julia", "run_server.jl"]
STOPSIGNAL KILL
