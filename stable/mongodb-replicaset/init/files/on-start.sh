#!/usr/bin/env bash

# Copyright 2016 The Kubernetes Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -x
# exec > /work-dir/debug.log 2>&1

replica_set=$REPLICA_SET
script_name=${0##*/}

if [[ "$AUTH" == "true" ]]; then
    admin_user="$ADMIN_USER"
    admin_password="$ADMIN_PASSWORD"
    admin_auth=(-u "$admin_user" -p "$admin_password")
fi

function log() {
    local msg="$1"
    local timestamp=$(date --iso-8601=ns)
    echo "[$timestamp] [$script_name] $msg" >> /work-dir/log.txt
}

function shutdown_mongo() {
    if [[ $# -eq 1 ]]; then
        args="timeoutSecs: $1"
    else
        args='force: true'
    fi
    log "Shutting down MongoDB ($args)..."
    mongo admin "${admin_auth[@]}" "${ssl_args[@]}" --eval "db.shutdownServer({$args})"
}

my_hostname=$(hostname)
log "Bootstrapping MongoDB replica set member: $my_hostname"

log "Reading standard input..."
while read -ra line; do
    if [[ "${line}" == *"${my_hostname}"* ]]; then
        service_name="$line"
        continue
    fi
    peers=("${peers[@]}" "$line")
done

# Generate the ca cert
ca_crt=/ca/tls.crt
if [ -f $ca_crt  ]; then
    log "Generating certificate"
    cp /ca/tls* /work-dir
    ca_crt=/work-dir/tls.crt
    ca_key=/work-dir/tls.key
    pem=/work-dir/mongo.pem
    ssl_args=(--ssl --sslCAFile $ca_crt --sslPEMKeyFile $pem)

cat >openssl.cnf <<EOL
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
countryName                     = Country Name (2 letter code)
stateOrProvinceName             = State or Province Name
localityName                    = Locality Name
0.organizationName              = Organization Name
organizationalUnitName          = Organizational Unit Name
commonName                      = Common Name
emailAddress                    = Email Address

# Optionally, specify some defaults.
countryName_default             = US
stateOrProvinceName_default     = CA
localityName_default            = San Jose
0.organizationName_default      = Nutanix
organizationalUnitName_default  = Xi

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = $(echo -n "$my_hostname" | sed s/-[0-9]*$//)
DNS.2 = $my_hostname
DNS.3 = $service_name
DNS.4 = localhost
DNS.5 = 127.0.0.1
EOL

    # Generate the certs
    openssl genrsa -out mongo.key 2048
    openssl req -new -key mongo.key -out mongo.csr -subj "/C=US/ST=CA/L=San Jose/O=Canaveral/OU=mongo/CN=$my_hostname" -config openssl.cnf
    openssl x509 -req -in mongo.csr \
        -CA $ca_crt -CAkey $ca_key -CAcreateserial \
        -out mongo.crt -days 3650 -extensions v3_req -extfile openssl.cnf

    rm mongo.csr
    cat mongo.crt mongo.key >> $pem
    rm mongo.key mongo.crt
    rm /work-dir/tls.key
fi

cat > /work-dir/mongos.conf << EOL
sharding:
  configDB: cfg/cfg-mongo-0.cfg-mongo.mongo.svc.cluster.local:27017,cfg-mongo-1.cfg-mongo.mongo.svc.cluster.local:27017,cfg-mongo-2.cfg-mongo.mongo.svc.cluster.local:27017
net:
  port: 27017
  bindIpAll: true
EOL

log "Hostname: $my_hostname"
if [[ $my_hostname == mongo* ]]; then
    mongos --config /work-dir/mongos.conf >> /work-dir/log.txt 2>&1 &

    log "Waiting for MongoDB to be ready..."
    until mongo "${ssl_args[@]}" --eval "db.adminCommand('ping')"; do
        log "Retrying..."
        sleep 2
    done
    log "Initialized."

    replica_sets="rs0 rs1 rs2"
    for rs in $replica_sets;
    do
        mongo "${ssl_args[@]}" --eval "sh.addShard(\"${rs}/${rs}-mongo-0.${rs}-mongo.mongo.svc.cluster.local:27017,${rs}-mongo-1.${rs}-mongo.mongo.svc.cluster.local:27017,${rs}-mongo-2.${rs}-mongo.mongo.svc.cluster.local:27017\")"
    done
    log "Creating admin user..."
    #mongo admin "${ssl_args[@]}" --eval "db.createUser({user: '$admin_user', pwd: '$admin_password', roles: ['userAdmin', 'userAdminAnyDatabase', 'clusterAdmin']})"
else
    log "Peers: ${peers[@]}"

    log "Starting a MongoDB instance..."
    mongod --config /config/mongod.conf >> /work-dir/log.txt 2>&1 &

    log "Waiting for MongoDB to be ready..."
    until mongo "${ssl_args[@]}" --eval "db.adminCommand('ping')"; do
        log "Retrying..."
        sleep 2
    done

    log "Initialized."

    # try to find a master and add yourself to its replica set.
    for peer in "${peers[@]}"; do
        mongo admin --host "$peer" "${admin_auth[@]}" "${ssl_args[@]}" --eval "rs.isMaster()" | grep '"ismaster" : true'
        if [[ $? -eq 0 ]]; then
            log "Found master: $peer"
            log "Adding myself ($service_name) to replica set..."
            mongo admin --host "$peer" "${admin_auth[@]}" "${ssl_args[@]}" --eval "rs.add('$service_name')"
            log "Done."

            shutdown_mongo "60"
            log "Good bye."
            exit 0
        fi
    done

    # else initiate a replica set with yourself.
    mongo "${ssl_args[@]}" --eval "rs.status()" | grep "no replset config has been received"
    if [[ $? -eq 0 ]]; then
        log "Initiating a new replica set with myself ($service_name)..."
        mongo "${ssl_args[@]}" --eval "rs.initiate({'_id': '$replica_set', 'members': [{'_id': 0, 'host': '$service_name'}]})"

        mongo "${ssl_args[@]}" --eval "rs.status()"

        if [[ "$AUTH" == "true" ]]; then
            # sleep a little while just to be sure the initiation of the replica set has fully
            # finished and we can create the user
            sleep 3

            log "Creating admin user..."
            mongo admin "${ssl_args[@]}" --eval "db.createUser({user: '$admin_user', pwd: '$admin_password', roles: [{role: 'root', db: 'admin'}]})"
        fi

        log "Done."
    fi

    shutdown_mongo
    log "Good bye."
fi