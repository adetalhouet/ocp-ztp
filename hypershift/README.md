# Setup Hypershift addon and AI for MCE on hub cluster

~~~
echo "---
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: hypershift-addon
  namespace: local-cluster
spec:
  installNamespace: open-cluster-management-agent-addon
---
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: hypershift-operator-oidc-provider-bucket
  namespace: local-cluster
spec:
  additionalConfig:
    bucketclass: noobaa-default-bucket-class
  generateBucketName: hypershift-operator-oidc-provider-bucket
  objectBucketName: obc-hypershift-operator-oidc-provider-bucket
  storageClassName: openshift-storage.noobaa.io" | oc apply -f -


mkdir -p $HOME/.aws
touch $HOME/.aws/credentials

# Retrieve bucket creds information and create the file
echo "[default]
aws_access_key_id = Vrf8cnGcl8YJMiJjeQVG
aws_secret_access_key = nl86JkFd7djRcyJrt3Oe08AiNMtPyAD5fbRsvcqj" > $HOME/.aws/credentials

oc create secret generic hypershift-operator-oidc-provider-s3-credentials \
  --from-file=credentials=$HOME/.aws/credentials \
  --from-literal=bucket=hypershift-operator-oidc-p-e8c50eb0-7df3-4f27-ac24-2a5ad714b4d7 \
  --from-literal=region=Montreal \
  -n local-cluster

oc label secret hypershift-operator-oidc-provider-s3-credentials -n local-cluster cluster.open-cluster-management.io/backup=""

export DB_VOLUME_SIZE="10Gi"
export FS_VOLUME_SIZE="10Gi"
export OCP_VERSION="4.10"
export ARCH="x86_64"
export OCP_RELEASE_VERSION=$(curl -s https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/latest-${OCP_VERSION}/release.txt | awk '/machine-os / { print $2 }')
export ISO_URL="https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/${OCP_VERSION}/latest/rhcos-${OCP_VERSION}.16-${ARCH}-live.${ARCH}.iso"
export ROOT_FS_URL="https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/${OCP_VERSION}/latest/rhcos-live-rootfs.${ARCH}.img"

envsubst <<"EOF" | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: AgentServiceConfig
metadata:
 name: agent
 namespace: multicluster-engine
spec:
  databaseStorage:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: ${DB_VOLUME_SIZE}
  filesystemStorage:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: ${FS_VOLUME_SIZE}
  osImages:
    - openshiftVersion: "${OCP_VERSION}"
      version: "${OCP_RELEASE_VERSION}"
      url: "${ISO_URL}"
      rootFSUrl: "${ROOT_FS_URL}"
      cpuArchitecture: "${ARCH}"
EOF
~~~

# Setup DNS entries for hypershift cluster

Points to one of the hub cluster nodes. This is for the hosted cluster API server, which is exposed through NodePort
~~~
api-server.hypershift-test.adetalhouet.ca.	IN	A	192.168.123.10
~~~

Points to one of the workers of the hypershift cluster. This is to provide ingress. Keepalived could be used with HAProxy to setup a VIP instead.
~~~
*.apps.hypershift-test.adetalhouet.ca.	IN	A	192.168.123.20
~~~

# Create the hypershift cluster namespace

`oc create ns hypershift-test`

# Create ssh and pull-secret secret

~~~
export SSH_PUB_KEY=$(cat $HOME/.ssh/id_rsa.pub)
envsubst <<"EOF" | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: agent-demo-ssh-key
  namespace: hypershift-test
stringData:
  id_rsa.pub: ${SSH_PUB_KEY}
EOF

DOCKER_CONFIG_JSON=`oc extract secret/pull-secret -n openshift-config --to=-`
oc create secret generic pull-secret \
    -n hypershift-test \
    --from-literal=.dockerconfigjson="$DOCKER_CONFIG_JSON" \
    --type=kubernetes.io/dockerconfigjson
~~~

# Create InfraEnv

~~~
envsubst <<"EOF" | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: hypershift-test
  namespace: hypershift-test
spec:
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: ${SSH_PUB_KEY}
EOF
~~~

# Create BareMetalHost consuming the above InfraEnv

~~~
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ca-regina-node1
  namespace: hypershift-test
  labels:
    infraenvs.agent-install.openshift.io: "hypershift-test"
  annotations:
    inspect.metal3.io: disabled
    bmac.agent-install.openshift.io/hostname: "ca-regina-node1"
spec:
  online: true
  bmc:
    address: redfish-virtualmedia+http://10.0.0.250:8000/redfish/v1/Systems/d72df842-5dc0-4d9b-a512-1cc94d448d50
    credentialsName: ca-regina-node1-secret
    disableCertificateVerification: true
  bootMACAddress: 02:04:00:00:01:01
  automatedCleaningMode: disabled
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ca-regina-node2
  namespace: hypershift-test
  labels:
    infraenvs.agent-install.openshift.io: "hypershift-test"
  annotations:
    inspect.metal3.io: disabled
    bmac.agent-install.openshift.io/hostname: "ca-regina-node2"
spec:
  online: true
  bmc:
    address: redfish-virtualmedia+http://10.0.0.250:8000/redfish/v1/Systems/05ec24af-9599-43f6-a4c2-a95e1f9372e0
    credentialsName: ca-regina-node2-secret
    disableCertificateVerification: true
  bootMACAddress: 02:04:00:00:01:02
  automatedCleaningMode: disabled
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ca-regina-node3
  namespace: hypershift-test
  labels:
    infraenvs.agent-install.openshift.io: "hypershift-test"
  annotations:
    inspect.metal3.io: disabled
    bmac.agent-install.openshift.io/hostname: "ca-regina-node3"
spec:
  online: true
  bmc:
    address: redfish-virtualmedia+http://10.0.0.250:8000/redfish/v1/Systems/d03f44c0-2431-4f91-b813-f6af0b8588b1
    credentialsName: ca-regina-node3-secret
    disableCertificateVerification: true
  bootMACAddress: 02:04:00:00:01:03
  automatedCleaningMode: disabled
---
# dummy secret - it is not used by required by assisted service and bare metal operator
apiVersion: v1
kind: Secret
metadata:
  name: ca-regina-node1-secret
  namespace: hypershift-test
data:
  password: Ym9iCg==
  username: Ym9iCg==
type: Opaque
---
# dummy secret - it is not used by required by assisted service and bare metal operator
apiVersion: v1
kind: Secret
metadata:
  name: ca-regina-node2-secret
  namespace: hypershift-test
data:
  password: Ym9iCg==
  username: Ym9iCg==
type: Opaque
---
# dummy secret - it is not used by required by assisted service and bare metal operator
apiVersion: v1
kind: Secret
metadata:
  name: ca-regina-node3-secret
  namespace: hypershift-test
data:
  password: Ym9iCg==
  username: Ym9iCg==
type: Opaque
~~~

# Patch Agents to approve, set role and define installation disk

~~~
 oc get agents -n hypershift-test -o name | xargs oc patch -n hypershift-test -p '{"spec":{"installation_disk_id":"/dev/vda","approved":true,"role":"worker"}}' --type merge
~~~

# Create HypershiftDeployment
This will deploy both the control plane and the workers.

~~~
apiVersion: cluster.open-cluster-management.io/v1alpha1
kind: HypershiftDeployment
metadata:
  name: hypershift-test
  namespace: hypershift-test
spec:
  hostingCluster: hypershift-test
  hostingNamespace: clusters
  infrastructure:
    configure: false 
  hostedClusterSpec:
    dns:
      baseDomain: adetalhouet.ca
    infraID: hypershift-test
    networking:
      machineCIDR: ""
      networkType: OpenShiftSDN
      podCIDR: 10.132.0.0/14
      serviceCIDR: 172.32.0.0/16
    platform:
      agent:
        agentNamespace: hypershift-test
      type: Agent
    pullSecret:
      name: pull-secret
    release:
      image: quay.io/openshift-release-dev/ocp-release:4.10.16-x86_64
    services:
      - service: APIServer
        servicePublishingStrategy:
          nodePort:
            address: api.hypershift-test.adetalhouet.ca
          type: NodePort
      - service: OAuthServer
        servicePublishingStrategy:
          type: Route
      - service: OIDC
        servicePublishingStrategy:
          type: None
      - service: Konnectivity
        servicePublishingStrategy:
          type: Route
      - service: Ignition
        servicePublishingStrategy:
          type: Route
      - service: OVNSbDb
        servicePublishingStrategy:
          type: Route
    sshKey:
      name: agent-demo-ssh-key
  nodePools:
  - name: nodepool
    spec:
      clusterName: hypershift-test
      management:
        autoRepair: false
        replace:
          rollingUpdate:
            maxSurge: 1
            maxUnavailable: 0
          strategy: RollingUpdate
        upgradeType: Replace
      platform:
        type: Agent
      release:
        image: quay.io/openshift-release-dev/ocp-release:4.10.16-x86_64
      replicas: 1
~~~


# Additional details

https://hypershift-docs.netlify.app/how-to/agent/create-agent-cluster/

https://github.com/stolostron/hypershift-deployment-controller/blob/main/docs/provision_hypershift_clusters_by_mce.md#provision-a-hypershift-hosted-cluster-on-bare-metal