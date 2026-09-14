






CREATE TABLE alembic_version (
    version_num character varying(32) NOT NULL
);



CREATE TABLE route_stops (
    route_id character varying(9) NOT NULL,
    sequence integer NOT NULL,
    station_id character varying(5) NOT NULL
);



CREATE TABLE routes (
    route_id character varying(9) NOT NULL,
    name character varying(128) NOT NULL
);



CREATE TABLE stations (
    station_id character varying(5) NOT NULL,
    node_id character varying(9) NOT NULL,
    name character varying(128) NOT NULL,
    longitude double precision NOT NULL,
    latitude double precision NOT NULL
);



ALTER TABLE ONLY alembic_version
    ADD CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num);



ALTER TABLE ONLY route_stops
    ADD CONSTRAINT route_stops_pkey PRIMARY KEY (route_id, sequence);



ALTER TABLE ONLY routes
    ADD CONSTRAINT routes_pkey PRIMARY KEY (route_id);



ALTER TABLE ONLY stations
    ADD CONSTRAINT stations_pkey PRIMARY KEY (station_id);



ALTER TABLE ONLY route_stops
    ADD CONSTRAINT uq_route_stop UNIQUE (route_id, station_id, sequence);



CREATE INDEX ix_route_stops_station_id ON route_stops USING btree (station_id);



CREATE INDEX ix_routes_name ON routes USING btree (name);



CREATE INDEX ix_stations_name ON stations USING btree (name);



CREATE INDEX ix_stations_node_id ON stations USING btree (node_id);



ALTER TABLE ONLY route_stops
    ADD CONSTRAINT route_stops_route_id_fkey FOREIGN KEY (route_id) REFERENCES routes(route_id) ON DELETE CASCADE;



ALTER TABLE ONLY route_stops
    ADD CONSTRAINT route_stops_station_id_fkey FOREIGN KEY (station_id) REFERENCES stations(station_id) ON DELETE CASCADE;




INSERT INTO alembic_version VALUES ('0001');
