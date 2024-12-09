#!/bin/bash
LOCATION=eastus2
FLEET_MEMBER_GROUP=myfleet-rg
FLEET_HUB_GROUP=hub-rg
ASO_CLUSTER=asocluster-aks
FLEET_CLUSTER=hub-fleet
SUBID=$(az account show -o tsv --query id)
TENANT=$(az account show -o tsv --query tenantId)

# Create a resource group
az group create -n $FLEET_MEMBER_GROUP -l $LOCATION

# Create a managed identity with contributor access to the resource group
IDENTITY=$(az identity create -g $FLEET_HUB_GROUP -n aso-cluster-creator -o tsv --query clientId)
az role assignment create --role "Contributor" --assignee $IDENTITY --scope /subscriptions/$SUBID/resourceGroups/$FLEET_MEMBER_GROUP

# Create an AKS cluster that will server as the ASO host
ASOID=$(az aks create -g $FLEET_HUB_GROUP -n $ASO_CLUSTER --node-count 1 --enable-oidc-issuer --generate-ssh-keys -o tsv --query id)
ISSUER=$(az aks show -g $FLEET_HUB_GROUP -n $ASO_CLUSTER -o json | jq -r '.oidcIssuerProfile.issuerUrl')

# Establish Trust between the AKS cluster and the managed identity
az identity federated-credential create --name aso-federated-credential \
    --identity-name aso-cluster-creator -g $FLEET_HUB_GROUP \
    --issuer $ISSUER \
    --subject "system:serviceaccount:azureserviceoperator-system:azureserviceoperator-default" \
    --audiences "api://AzureADTokenExchange"

# Install Azure Service Operator on the cluster
az aks get-credentials -g $FLEET_HUB_GROUP -n $ASO_CLUSTER --overwrite-existing

# ASO requires cert manager
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.14.1/cert-manager.yaml

# Helm install ASOv2
helm repo add aso2 https://raw.githubusercontent.com/Azure/azure-service-operator/main/v2/charts
helm upgrade --install aso2 aso2/azure-service-operator \
        --create-namespace \
        --namespace=azureserviceoperator-system \
        --set azureSubscriptionID=$SUBID \
        --set azureTenantID=$TENANT \
        --set azureClientID=$IDENTITY \
        --set useWorkloadIdentityAuth=true \
        --set crdPattern='resources.azure.com/*;containerservice.azure.com/*'

# Join the cluster to the fleet
az fleet member create -g $FLEET_HUB_GROUP -f $FLEET_CLUSTER -n $ASO_CLUSTER --member-cluster-id $ASOID

# Label the cluster as an ASO host
az fleet get-credentials -g $FLEET_HUB_GROUP -n $FLEET_CLUSTER --overwrite-existing
kubectl label cluster $ASO_CLUSTER clusterType=aso

# Install cluster-definitions on fleet
kubectl create ns cluster-definitions
kubectl apply -f ./fleet/cluster-definitions/

# Install the CRP for the cluster definitions
kubectl apply -f ./fleet/placements/