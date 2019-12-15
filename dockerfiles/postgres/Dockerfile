FROM postgres:9.6

RUN apt-get update \
    && apt-get install -y \
        postgresql-${PG_MAJOR}-plv8 \
        postgresql-plperl-${PG_MAJOR} \
        postgresql-pltcl-${PG_MAJOR}

RUN apt-get clean \
    && rm -rf /tmp/build /var/lib/apt/lists/*

RUN echo 'CREATE EXTENSION plv8;' > /docker-entrypoint-initdb.d/create-plv8.sql \
    && echo 'CREATE EXTENSION plperl;' > /docker-entrypoint-initdb.d/create-plperl.sql \
    && echo 'CREATE EXTENSION pltcl;' > /docker-entrypoint-initdb.d/create-pltcl.sql \
    && echo 'CREATE EXTENSION pltclu;' > /docker-entrypoint-initdb.d/create-pltclu.sql
