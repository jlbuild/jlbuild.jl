FROM staticfloat/julia:v0.5-x64

WORKDIR /app

RUN apt update && apt install -y unzip build-essential libmysqlclient-dev git

RUN mkdir -p /app/deps
RUN julia -e 'LibGit2.clone("https://github.com/JuliaLang/julia.git", "deps/julia", isbare=true)'

# Install packages
RUN julia -e 'for pkg in ["Compat", "HTTP", "GitHub", "MySQL", "TimeZones"]; Pkg.add(pkg); end; Pkg.checkout("MySQL"); Pkg.build();'

COPY src /app/src
COPY test /app/test
COPY run_server.jl /app/
COPY shell.jl /app/
RUN julia -e 'include("src/jlbuild.jl"); using jlbuild; jlbuild.update_julia_repo()'
CMD ["julia", "run_server.jl"]
STOPSIGNAL KILL
