#!/bin/bash


oc create ns ca-montreal

export SSH_PUB_KEY=$(cat $HOME/.ssh/id_rsa.pub)
envsubst <<"EOF" | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: agent-demo-ssh-key
  namespace: ca-montreal
stringData:
  id_rsa.pub: ${SSH_PUB_KEY}
EOF

DOCKER_CONFIG_JSON=`oc extract secret/pull-secret -n openshift-config --to=-`
oc create secret generic pull-secret \
    -n ca-montreal \
    --from-literal=.dockerconfigjson="$DOCKER_CONFIG_JSON" \
    --type=kubernetes.io/dockerconfigjson

envsubst <<"EOF" | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ca-montreal
  namespace: ca-montreal
  labels:
    agentclusterinstalls.extensions.hive.openshift.io/location: Montreal
spec:
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: ${SSH_PUB_KEY}
  agentLabelSelector:
    matchLabels:
      agentclusterinstalls.extensions.hive.openshift.io/location: Montreal
EOF

echo "
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ca-montreal-node1
  namespace: ca-montreal
  labels:
    infraenvs.agent-install.openshift.io: "ca-montreal"
  annotations:
    inspect.metal3.io: disabled
    bmac.agent-install.openshift.io/hostname: "ca-montreal-node1"
spec:
  online: true
  bmc:
    address: redfish-virtualmedia+http://192.168.0.190:8000/redfish/v1/Systems/d4e63915-eebf-4948-b1b3-542a11a4286a
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
  namespace: ca-montreal
data:
  password: Ym9iCg==
  username: Ym9iCg==
type: Opaque" | oc apply -f -

echo "
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: capi-provider-role
  namespace: ca-montreal
rules:
- apiGroups:
  - agent-install.openshift.io
  resources:
  - agents
  verbs:
  - '*'
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
    enabled: true" | oc apply -f -