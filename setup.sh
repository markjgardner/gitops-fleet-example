#!/bin/bash
LOCATION=eastus2
FLEET_MEMBER_GROUP=myfleet-rg
FLEET_HUB_GROUP=hub-rg
CAPZ_CLUSTER=capzcluster-aks
FLEET_CLUSTER=hub-fleet

# Create resource groups
az group create -n $FLEET_HUB_GROUP -l $LOCATION
az group create -n $FLEET_MEMBER_GROUP -l $LOCATION

# Create fleet hub
az fleet create -g $FLEET_HUB_GROUP -n $FLEET_CLUSTER -l $LOCATION --enable-hub --enable-managed-identity
az role assignment create --role "Azure Kubernetes Fleet Manager Contributor Role" --assignee $(az account show --query user.name -o tsv) --scope /subscriptions/$SUBID/resourceGroups/$FLEET_HUB_GROUP

# Create a managed identity with necessary permissions
SUBID=$(az account show -o tsv --query id)
TENANT=$(az account show -o tsv --query tenantId)
CAPZ_MI=capz-contributor
CLIENTID=$(az identity create -g $FLEET_HUB_GROUP -n $CAPZ_MI -o tsv --query clientId)
az role assignment create --role "Contributor" --assignee $CLIENTID --scope /subscriptions/$SUBID/resourceGroups/$FLEET_MEMBER_GROUP
az role assignment create --role "Reader" --assignee $CLIENTID --scope /subscriptions/$SUBID/resourceGroups/$FLEET_HUB_GROUP
az role assignment create --role "Azure Kubernetes Fleet Manager Contributor Role" --assignee $CLIENTID --scope /subscriptions/$SUBID/resourceGroups/$FLEET_HUB_GROUP


# Create an AKS cluster that will serve as the CAPZ cluster
CAPZ_CLUSTER_ID=$(az aks create -g $FLEET_HUB_GROUP -n $CAPZ_CLUSTER --node-count 1 --enable-oidc-issuer --enable-workload-identity --generate-ssh-keys -o tsv --query id)
ISSUER=$(az aks show -g $FLEET_HUB_GROUP -n $CAPZ_CLUSTER -o json | jq -r '.oidcIssuerProfile.issuerUrl')

# Establish Trust between the CAPZ ans ASO operators and the managed identity
az identity federated-credential create --name capz-federated-credential \
    --identity-name $CAPZ_MI -g $FLEET_HUB_GROUP \
    --issuer $ISSUER \
    --subject "system:serviceaccount:capz-system:capz-manager" \
    --audiences "api://AzureADTokenExchange"
az identity federated-credential create --name aso-federated-credential \
    --identity-name $CAPZ_MI -g $FLEET_HUB_GROUP \
    --issuer $ISSUER \
    --subject "system:serviceaccount:capz-system:azureserviceoperator-default" \
    --audiences "api://AzureADTokenExchange"

# Install CAPZ on the cluster
az aks get-credentials -g $FLEET_HUB_GROUP -n $CAPZ_CLUSTER --overwrite-existing

# The following envvars are used to configure the managed identity used by capz and aso
export AZURE_TENANT_ID=$TENANT
export AZURE_SUBSCRIPTION_ID=$SUBID
export AZURE_CLIENT_ID=$CLIENTID
# TODO: verify this work otherwise you have to explicitly set them in the secrets post capz init
clusterctl init --infrastructure azure

# Join the cluster to the fleet
az fleet member create -g $FLEET_HUB_GROUP -f $FLEET_CLUSTER -n $CAPZ_CLUSTER --member-cluster-id $CAPZ_CLUSTER_ID

# Label the cluster as the CAPZ cluster
az fleet get-credentials -g $FLEET_HUB_GROUP -n $FLEET_CLUSTER --overwrite-existing
kubectl label cluster $CAPZ_CLUSTER clusterType=capz

# define clusters
kubectl create ns cluster-definitions
kubectl apply -f ./fleet/cluster-definitions/


# Install the CRPs
kubectl apply -f ./fleet/placements/