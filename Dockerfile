FROM julia

WORKDIR /app

RUN apt update && apt install -y unzip build-essential libmysqlclient-dev git
# Make sure we track HTTP.jl closely
ADD https://api.github.com/repos/JuliaWeb/HTTP.jl/git/refs/heads/master /HTTP.jl.json
RUN julia -e 'Pkg.clone("HTTP"); Pkg.add("GitHub"); Pkg.clone("MySQL"); Pkg.add("TimeZones"); Pkg.build();'

RUN mkdir -p /app/deps
RUN git clone --bare https://github.com/JuliaLang/julia.git /app/deps/julia

COPY src /app/src
COPY test /app/test
COPY run_server.jl /app/run_server.jl
RUN julia -e 'include("src/jlbuild.jl"); using jlbuild; jlbuild.update_julia_repo()'
CMD ["julia", "run_server.jl"]
STOPSIGNAL KILL
