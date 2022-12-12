# Setup Hypershift addon and AI for MCE with ACM hub cluster

Start by reading the official product [documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.5/html/clusters/managing-your-clusters#hosted-control-plane-intro)


## Table of Contents

<!-- TOC -->
- [Enable the hypershift related components on the hub cluster](#enable-the-hypershift-related-components-on-the-hub-cluster)
- [Turn one of the managed clusters into the HyperShift management cluster](#turn-one-of-the-managed-clusters-into-the-hypershift-management-cluster)
- [Patch the provisioning CR to watch all namespace](#patch-the-provisioning-cr-to-watch-all-namespace)
- [Create Assisted Installer service in MCE namespace](#create-assisted-installer-service-in-mce-namespace)
- [Setup DNS entries for hypershift cluster](#setup-dns-entries-for-hypershift-cluster)
- [Create the hypershift cluster namespace](#create-the-hypershift-cluster-namespace)
- [Create ssh and pull-secret secret](#create-ssh-and-pull-secret-secret)
- [Create the InfraEnv](#create-infraenv)
- [Create BareMetalHost consuming the above InfraEnv](#create-baremetalhost-consuming-the-above-infraenv)
- [Create HypershiftDeployment](#create-hypershiftdeployment)
<!-- TOC -->

## [Enable the hypershift related components on the hub cluster](https://github.com/stolostron/hypershift-deployment-controller/blob/main/docs/provision_hypershift_clusters_by_mce.md#enable-the-hosted-control-planes-related-components-on-the-hub-cluster)

~~~
oc patch mce multiclusterengine --type=merge -p '{"spec":{"overrides":{"components":[{"name":"hypershift-preview","enabled": true}]}}}'
~~~

## [Turn one of the managed clusters into the HyperShift management cluster](https://github.com/stolostron/hypershift-deployment-controller/blob/main/docs/provision_hypershift_clusters_by_mce.md#turn-one-of-the-managed-clusters-into-the-hypershift-management-cluster)

In my case, I will use `local-cluster` 

Below is how to create the bucket using ODF.

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
~~~

Bellow is how to create the secret for hypershift consuming the bucket credentials.

~~~
ACCESS_KEY=$(oc get secret hypershift-operator-oidc-provider-bucket -n local-cluster --template={{.data.AWS_ACCESS_KEY_ID}} | base64 -d)
SECRET_KEY=$(oc get secret hypershift-operator-oidc-provider-bucket -n local-cluster --template={{.data.AWS_SECRET_ACCESS_KEY}} | base64 -d)

echo "[default]
aws_access_key_id = $ACCESS_KEY
aws_secret_access_key = $SECRET_KEY" > $HOME/bucket-creds

oc create secret generic hypershift-operator-oidc-provider-s3-credentials \
  --from-file=credentials=$HOME/bucket-creds \
  --from-literal=bucket=hypershift-operator-oidc-p-e8c50eb0-7df3-4f27-ac24-2a5ad714b4d7 \
  --from-literal=region=Montreal \
  -n local-cluster

oc label secret hypershift-operator-oidc-provider-s3-credentials -n local-cluster cluster.open-cluster-management.io/backup=""
~~~

## Patch the `provisioning` CR to watch all namespace

~~~
oc patch provisioning provisioning-configuration --type merge -p '{"spec":{"watchAllNamespaces": true }}'
~~~

## Create Assisted Installer service in MCE namespace

~~~
export DB_VOLUME_SIZE="10Gi"
export FS_VOLUME_SIZE="10Gi"
export OCP_VERSION="4.10"
export ARCH="x86_64"
export OCP_RELEASE_VERSION=$(curl -s https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/latest-${OCP_VERSION}/release.txt | awk '/machine-os / { print $2 }')
export ISO_URL="https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/${OCP_VERSION}/4.10.16/rhcos-${OCP_VERSION}.16-${ARCH}-live.${ARCH}.iso"
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

## Setup DNS entries for hypershift cluster
The bellow example uses bind as DNS server.

Two records are required for the hypershift cluster to be functional and accessible.
The first on is for the hosted cluster API server, which is exposed through NodePort
This IP is one of the ACM cluster node.
~~~
api-server.hypershift-test.adetalhouet.ca.	IN	A	192.168.123.10
~~~

The second one is to provide ingress. Better solution could be implemented to have keepavlive and load balancing between the workers.
The IP is one of the hypershift cluster's worker node.
~~~
*.apps.hypershift-test.adetalhouet.ca.	IN	A	192.168.123.20
~~~

## Create the hypershift cluster namespace

`oc create ns hypershift-test`

## Create ssh and pull-secret secret 
So we can provision the bare metal node and access them later on.

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

## Create InfraEnv

This will will generate the ISO used to boostrap the baremetal nodes

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

## Create BareMetalHost consuming the above InfraEnv. 
Under the hood, OpenShift will load the ISO and start the bare metal node. The agent part of the ISO will register the node with Assisted Installer.

~~~
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ca-montreal-node1
  namespace: hypershift-test
  labels:
    infraenvs.agent-install.openshift.io: "hypershift-test"
  annotations:
    inspect.metal3.io: disabled
    bmac.agent-install.openshift.io/hostname: "ca-montreal-node1"
spec:
  online: true
  bmc:
    address: redfish-virtualmedia+http://192.168.0.190:8000/redfish/v1/Systems/a59aa864-afa2-4363-a8c2-eac2edb63234
    credentialsName: ca-montreal-node1-secret
    disableCertificateVerification: true
  bootMACAddress: 02:04:00:00:01:03
  automatedCleaningMode: disabled
---
# dummy secret - it is not used by required by assisted service and bare metal operator
apiVersion: v1
kind: Secret
metadata:
  name: ca-montreal-node1-secret
  namespace: hypershift-test
data:
  password: Ym9iCg==
  username: Ym9iCg==
type: Opaque
~~~

Patch the corresponding bare metal node agents to approve, set role and define installation disk

~~~
 oc get agents -n hypershift-test -o name | xargs oc patch -n hypershift-test -p '{"spec":{"installation_disk_id":"/dev/vda","approved":true,"role":"worker"}}' --type merge
~~~

## Create Hypershift Deployment

### Create role for Cluster API provider
~~~
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  creationTimestamp: null
  name: capi-provider-role
  namespace: ca-montreal
rules:
- apiGroups:
  - agent-install.openshift.io
  resources:
  - agents
  verbs:
  - '*'
~~~

### Create hosted control plane
~~~
---
apiVersion: hypershift.openshift.io/v1alpha1
kind: HostedCluster
metadata:
  name: 'ca-montreal'
  namespace: 'ca-montreal'
  labels:
    "cluster.open-cluster-management.io/clusterset": 'default'
spec:
  fips: false
  release:
    image: 'quay.io/openshift-release-dev/ocp-release:4.10.26-x86_64'
  dns:
    baseDomain: adetalhouet.ca
  controllerAvailabilityPolicy: SingleReplica
  infraID: ca-montreal
  etcd:
    managed:
      storage:
        persistentVolume:
          size: 4Gi
        type: PersistentVolume
    managementType: Managed
  infrastructureAvailabilityPolicy: SingleReplica
  platform:
    agent:
      agentNamespace: ca-montreal
    type: Agent
  networking:
    clusterNetwork:
      - cidr: 10.132.0.0/14
    machineNetwork:
      - cidr: 192.168.123.0/24
    networkType: OVNKubernetes
    serviceNetwork:
      - cidr: 172.31.0.0/16
  clusterID: af5d43f0-0936-49cf-88a3-79736034adb2
  pullSecret:
    name: pull-secret
  issuerURL: 'https://kubernetes.default.svc'
  sshKey:
    name: agent-demo-ssh-key
  autoscaling: {}
  olmCatalogPlacement: management
  services:
    - service: APIServer
      servicePublishingStrategy:
        nodePort:
          address: api-server.ca-montreal.adetalhouet.ca
        type: NodePort
    - service: OAuthServer
      servicePublishingStrategy:
        type: Route
    - service: Konnectivity
      servicePublishingStrategy:
        type: Route
    - service: Ignition
      servicePublishingStrategy:
        type: Route
~~~

### Create node pool consuming our bare metal hosts
~~~
---
apiVersion: hypershift.openshift.io/v1alpha1
kind: NodePool
metadata:
  name: 'nodepool-ca-montreal-1'
  namespace: 'ca-montreal'
spec:
  clusterName: 'ca-montreal'
  replicas: 1
  management:
    autoRepair: false
    upgradeType: InPlace
  platform:
    type: Agent
    agent:
      agentLabelSelector:
        matchLabels: {}
  release:
    image: quay.io/openshift-release-dev/ocp-release:4.10.26-x86_64
~~~

### Import cluster in ACM
~~~
---
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  labels:
    cloud: hybrid
    name: ca-montreal
    cluster.open-cluster-management.io/clusterset: 'default'
  name: ca-montreal
spec:
  hubAcceptsClient: true
---
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: 'ca-montreal'
  namespace: 'ca-montreal'
spec:
  clusterName: 'ca-montreal'
  clusterNamespace: 'ca-montreal'
  clusterLabels:
    cloud: ai-hypershift
  applicationManager:
    enabled: true
  policyController:
    enabled: true
  searchCollector:
    enabled: true
  certPolicyController:
    enabled: true
  iamPolicyController:
    enabled: true
~~~


# Additional details

https://github.com/openshift/hypershift/blob/main/docs/content/how-to/agent/create-agent-cluster.md

https://hypershift-docs.netlify.app/how-to/agent/create-agent-cluster/

https://github.com/stolostron/hypershift-deployment-controller/blob/main/docs/provision_hypershift_clusters_by_mce.md#provision-a-hypershift-hosted-cluster-on-bare-metal
