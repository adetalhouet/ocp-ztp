#!/bin/bash


oc create ns ca-regina

export SSH_PUB_KEY=$(cat $HOME/.ssh/id_rsa.pub)
envsubst <<"EOF" | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: agent-demo-ssh-key
  namespace: ca-regina
stringData:
  id_rsa.pub: ${SSH_PUB_KEY}
EOF

DOCKER_CONFIG_JSON=`oc extract secret/pull-secret -n openshift-config --to=-`
oc create secret generic pull-secret \
    -n ca-regina \
    --from-literal=.dockerconfigjson="$DOCKER_CONFIG_JSON" \
    --type=kubernetes.io/dockerconfigjson

envsubst <<"EOF" | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ca-regina
  namespace: ca-regina
spec:
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: ${SSH_PUB_KEY}
EOF

echo "
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ca-regina-node1
  namespace: ca-regina
  labels:
    infraenvs.agent-install.openshift.io: "ca-regina"
  annotations:
    inspect.metal3.io: disabled
    bmac.agent-install.openshift.io/hostname: "ca-regina-node1"
spec:
  online: true
  bmc:
    address: redfish-virtualmedia+http://10.0.0.250:8000/redfish/v1/Systems/10f4501a-cbbd-43ee-ba1f-3b8f9bc36a53
    credentialsName: ca-regina-node1-secret
    disableCertificateVerification: true
  bootMACAddress: 02:04:00:00:01:01
  automatedCleaningMode: disabled
---
# dummy secret - it is not used by required by assisted service and bare metal operator
apiVersion: v1
kind: Secret
metadata:
  name: ca-regina-node1-secret
  namespace: ca-regina
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
  namespace: ca-regina
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
  name: 'ca-regina'
  namespace: 'ca-regina'
  labels:
    "cluster.open-cluster-management.io/clusterset": 'default'
spec:
  release:
    image: quay.io/openshift-release-dev/ocp-release:4.10.26-x86_64
  pullSecret:
    name: pull-secret
  sshKey:
    name: agent-demo-ssh-key
  networking:
    podCIDR: 10.132.0.0/14
    serviceCIDR: 172.31.0.0/16
    machineCIDR: 192.168.123.0/24
    networkType: OpenShiftSDN
  platform:
    type: Agent
    agent:
      agentNamespace: 'ca-regina'
  infraID: 'ca-regina'
  dns:
    baseDomain: 'adetalhouet.ca'
  services:
      - service: APIServer
        servicePublishingStrategy:
          nodePort:
            address: api-server.ca-regina.adetalhouet.ca
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
---
apiVersion: hypershift.openshift.io/v1alpha1
kind: NodePool
metadata:
  name: 'nodepool-ca-regina-1'
  namespace: 'ca-regina'
spec:
  clusterName: 'ca-regina'
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
    name: ca-regina
    cluster.open-cluster-management.io/clusterset: 'default'
  name: ca-regina
spec:
  hubAcceptsClient: true
---
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: 'ca-regina'
  namespace: 'ca-regina'
spec:
  clusterName: 'ca-regina'
  clusterNamespace: 'ca-regina'
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