#!/bin/bash

: ${REGION:=$(aws configure get region)}
: ${AWS_REGION:=${REGION}}
: ${EXTERNALDASHBOARD:=yes}
: ${EXTERNALPROMETHEUS:=yes}
: ${NAMESPACE:="kube-system"}
: ${MESH_NAME:="ekstender-mesh"}
: ${MESH_REGION:=${REGION}}
export REGION
export AWS_REGION
export EXTERNALDASHBOARD
export EXTERNALPROMETHEUS
export NAMESPACE
export MESH_NAME
export MESH_REGION

# scripts read $1 as clustername. If $1 is not used it exits
if [ -z "$1" ]; then echo "Please specify the cluster you want to clean up post EKStention!"; exit; else export CLUSTER_NAME=$1; fi
export ACCOUNT_ID=$(aws sts get-caller-identity --output json | jq -r '.Account') # the AWS Account ID
export STACK_NAME=$(eksctl get nodegroup --cluster $CLUSTER_NAME --region $REGION  -o json | jq -r '.[].StackName')
export NODE_INSTANCE_ROLE=$(aws cloudformation describe-stack-resources --region $REGION --stack-name $STACK_NAME | jq -r '.StackResources[] | select(.LogicalResourceId=="NodeInstanceRole") | .PhysicalResourceId' )  # the IAM role assigned to the worker nodes
export CLUSTER_VERSION=$(aws eks describe-cluster --name $CLUSTER_NAME | jq --raw-output .cluster.version) # the major/minor version of the EKS cluster
export VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME | jq --raw-output .cluster.resourcesVpcConfig.vpcId) # the VPC ID of the EKS cluster

echo ACCOUNT_ID          : $ACCOUNT_ID
echo STACK_NAME          : $STACK_NAME
echo NODE_INSTANCE_ROLE  : $NODE_INSTANCE_ROLE
echo CLUSTER_VERSION     : $CLUSTER_VERSION
echo VPC_ID              : $VPC_ID
echo REGION              : $REGION
echo AWS_REGION          : $AWS_REGION


kubectl delete -f https://raw.githubusercontent.com/mreferre/yelb/master/deployments/platformdeployment/Kubernetes/yaml/yelb-k8s-ingress-alb-ip.yaml --ignore-not-found -n default

kubectl delete service kubecost-external --namespace kubecost --ignore-not-found
helm delete kubecost --namespace kubecost
kubectl delete namespace kubecost --ignore-not-found

# the CRDs are the first to be installed in the docs (and so originally the last to be uninstalled here) but due to a racing condition moving their deletion at the top
kubectl delete --ignore-not-found -k https://github.com/aws/eks-charts/stable/appmesh-controller/crds?ref=master
eksctl delete iamserviceaccount --region $AWS_REGION --name appmesh-controller --namespace appmesh-system --cluster $CLUSTER_NAME
helm delete appmesh-controller --namespace appmesh-system
kubectl delete namespace appmesh-system --ignore-not-found
kubectl delete namespace appmesh-app --ignore-not-found

# Delete the CW agent beta for Prometheus deletes everything
template=`curl -sS https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/prometheus-beta/k8s-deployment-manifest-templates/deployment-mode/service/cwagent-prometheus/prometheus-eks.yaml`
echo "$template" | kubectl delete --ignore-not-found -f -
### CW Fluentd
### -----
##kubectl delete configmap cluster-info -n amazon-cloudwatch
### ------
##template=`curl -sS https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/fluentd/fluentd.yaml`
##echo "$template" | kubectl delete --ignore-not-found -f -
### CW agent daemonset
##template=`curl -sS https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cwagent/cwagent-daemonset.yaml`
##echo "$template" | kubectl delete --ignore-not-found -f -
### CW agent configmap
##template=`curl -sS https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cwagent/cwagent-configmap.yaml`
##echo "$template" | kubectl delete --ignore-not-found -f -
### CW service account
##template=`curl -sS https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cwagent/cwagent-serviceaccount.yaml`
##echo "$template" | kubectl delete --ignore-not-found -f -
### CW namespace
##template=`curl -sS https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cloudwatch-namespace.yaml`
##echo "$template" | kubectl delete --ignore-not-found -f -
#CW IAM role for EC2 instances
aws iam detach-role-policy --role-name $NODE_INSTANCE_ROLE --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

helm delete grafana --namespace grafana
kubectl delete namespace grafana --ignore-not-found

helm delete prometheus --namespace prometheus
kubectl delete namespace prometheus --ignore-not-found

kubectl delete service kubernetes-dashboard-external -n kubernetes-dashboard --ignore-not-found
kubectl delete --ignore-not-found -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta8/aio/deploy/recommended.yaml

# this script for some reason spits a couple of error messages at the end trying to delete 2 CRDs that it has deleted at the beginning
if [[ ! -d "autoscaler" ]]; then git clone -b vpa-release-0.8 https://github.com/kubernetes/autoscaler.git; fi
# the reason because the 0.8 branch is required is due to this issue: https://github.com/kubernetes/autoscaler/issues/3397
# if openssl111 is available then you could clone master
./autoscaler/vertical-pod-autoscaler/hack/vpa-down.sh
kubectl delete --ignore-not-found -f ./configurations/cluster_autoscaler.yaml

template=`curl -sS https://raw.githubusercontent.com/kubernetes-sigs/aws-alb-ingress-controller/v1.1.4/docs/examples/alb-ingress-controller.yaml | sed -e "s/# - --cluster-name=devCluster/- --cluster-name=$CLUSTER_NAME/g" -e "s/# - --aws-vpc-id=vpc-xxxxxx/- --aws-vpc-id=$VPC_ID/g" -e "s/# - --aws-region=us-west-1/- --aws-region=$AWS_REGION/g"`
echo "$template" | kubectl delete --ignore-not-found -f -
kubectl delete --ignore-not-found -f https://raw.githubusercontent.com/kubernetes-sigs/aws-alb-ingress-controller/v1.1.4/docs/examples/rbac-role.yaml
eksctl delete iamserviceaccount --region $AWS_REGION --name alb-ingress-controller --namespace kube-system --cluster $CLUSTER_NAME
sleep 5
aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/ALBIngressControllerIAMPolicy

#this order is not consistent with the setup order otherwise the kubectl delete throws an error (on the sa account not found)
kubectl delete --ignore-not-found -k "github.com/kubernetes-sigs/aws-fsx-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"
eksctl delete iamserviceaccount --cluster $CLUSTER_NAME --region $REGION --name fsx-csi-controller-sa --namespace kube-system
sleep 5
aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/Amazon_FSx_Lustre_CSI_Driver

kubectl delete --ignore-not-found -k "github.com/kubernetes-sigs/aws-efs-csi-driver/deploy/kubernetes/overlays/stable/ecr/?ref=release-1.0"

aws iam detach-role-policy --role-name $NODE_INSTANCE_ROLE --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/Amazon_EBS_CSI_Driver
aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/Amazon_EBS_CSI_Driver
kubectl delete --ignore-not-found -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"

OIDC_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --output json | jq -r .cluster.identity.oidc.issuer | sed -e "s*https://**")
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::$ACCOUNT_ID:oidc-provider/$OIDC_URL

helm delete metrics-server --namespace metrics-server
kubectl delete namespace metrics-server --ignore-not-found

# if Calico was installed (by default it is not) unsinstalling it is not enough. Worker nodes need to be cleaned of remaining IP tables
# See here for more information: https://github.com/projectcalico/calico/blob/master/hack/remove-calico-policy/remove-policy.md
template=`curl https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/release-1.6/config/v1.6/calico.yaml`
echo "$template" | kubectl delete --ignore-not-found -f -

template=`cat "./configurations/eks-admin-service-account.yaml" | sed -e "s/NAMESPACE/$NAMESPACE/g"`
echo "$template" | kubectl delete --ignore-not-found -f -

echo NAMESPACES:
kubectl get ns
echo
echo ALL:
kubectl get all -A
echo
echo PVs:
kubectl get pv
echo CRDs:
kubectl get crd -A
echo SAs:
kubectl get sa -A
