![alt text](https://raw.githubusercontent.com/cpouthier/tutorial/main/k10gh.png)
# Tutorial
The aim of this tutorial is to guide you through a full deployment of Kasten on a single node K3s running on a Linux VM (tested with Ubuntu 22.04).
K3s is a lightweight distribution of Kubernetes (K8s).

All scripts are inspired (and copied) from my fellow colleague James Tate (https://blog.kodu.uk/kasten-k10-guide-for-beginners-part-2/)

Please have a read to this entire tutorial before setting up your environment.
## Pre-requisites
The main pre-requisite is obviously to get a VM or bare metal server with Linux installed and superuser access. The superuser access (su) will be used in order to run scipts below and the fdisk utility to provide a new free partition (fdisk -l or fidsk /dev/xxx) we will format later on in zfs.

You also need to ensure to get **at least 8GB of memory and about 100GB of disk** to install all the tools, K3s, Minio...
All instructions below will be run as superuser (sudo su).
## Setup the environement
Before doing anything use the fdisk utility in order to provide (or ensure) you'll get a fresh free new unformatted disk partition.

Then, let's tune a little bit your Linux environement:
```console
sed -i 's/#$nrconf{restart} = '"'"'i'"'"';/$nrconf{restart} = '"'"'a'"'"';/g' /etc/needrestart/needrestart.conf
apt update
sysctl fs.inotify.max_user_watches=524288
sysctl fs.inotify.max_user_instances=512
echo "fs.inotify.max_user_watches = 524288" >> /etc/sysctl.conf
echo "fs.inotify.max_user_instances = 512" >> /etc/sysctl.conf
apt install apache2-utils -y
```
## Setup some environment variables
Now we need to set up some environement variables that we will use later in this tutorial. Kasten will be installed with basic authentication, hence the need to provide a username and a password. Same credentials will be used too to connect to Minio:
```console
echo -e "\033[0;31m Enter the username: \e[0m"
read username < /dev/tty
echo -e "\033[0;31m Enter the password: \e[0m"
read password < /dev/tty
htpasswd_entry=$(htpasswd -nbm "$username" "$password" | cut -d ":" -f 2)
htpasswd="$username:$htpasswd_entry"
echo "Successfully generated htpasswd entry: $htpasswd"
```
**WARNING: ensure you do not exit your console otherwise you'll loose those variable and you won't be able to perform a clean install with all instructions below!**

We also need to get the fresh new partition you created with fdisk utility to set up the zfs pool we will use to provide snapshot compatible storage to K3s.
```console
fdisk -l
echo ""
echo -e "\033[0;31m Identify and enter drive path of extra volume (ie /dev/sdb) to set up Kasten K10 zfs pool: \e[0m"
read DRIVE < /dev/tty
```
# Install some tools
## Install Helm
First of all we will install Helm which is a packet manager for Kubernetes:
```console
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x ./get_helm.sh
./get_helm.sh
```
## Install Kubectl
Then we need to install Kubectl which is the command line tool to communicate with Kubernetes and add autocompletion in bash. We'll also add an alias (k) to simplify further interaction in bash:
```console
curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
echo 'source <(kubectl completion bash)' >>~/.bashrc
source <(kubectl completion bash)
echo "alias k=kubectl" | tee -a .bashrc /root/.bashrc
alias k=kubectl
```
# Installing K3s
K3s will be installed as a single node cluster. We will disable traefik (default ingress controller) as we'll use nginx.
## Install K3s
```console
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable local-storage --disable=traefik" sh -s -
mkdir /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
chmod 600 ~/.kube/config && export KUBECONFIG=~/.kube/config
```
Wait 30 seconds in order for K3s to spin up and check the status:
```console
k3s check-config
kubectl cluster-info
kubectl get nodes -o wide
```
## Configure storage 
As already said, we will configure a ZFS storage pool which will provide snapshot functionnality for our kubernetes applications deployed on this K3s cluster.

### Install zfs and configure kasten-pool storage pool on associated drive
```console
apt install zfsutils-linux open-iscsi jq -y
zpool create kasten-pool $DRIVE
```
### Configure zfs storage class
```console
kubectl apply -f https://openebs.github.io/charts/zfs-operator.yaml

echo | kubectl apply -f - << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: kasten-zfs
parameters:
  recordsize: "4k"
  compression: "off"
  dedup: "off"
  fstype: "zfs"
  poolname: "kasten-pool"
provisioner: zfs.csi.openebs.io
EOF
```
### Configure zfs Volume Snaspshot class
```console
echo | kubectl apply -f - << EOF
kind: VolumeSnapshotClass
apiVersion: snapshot.storage.k8s.io/v1
metadata:
  name: kasten-zfs-snapclass
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: “true”
    k10.kasten.io/is-snapshot-class: "true"
driver: zfs.csi.openebs.io
deletionPolicy: Delete
EOF
```
### Annotate the Storage Class
```console
kubectl patch storageclass kasten-zfs -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```
# Installing Nginx
We will now install Nginx as our ingress controller for our K3s cluster:
```console
helm upgrade --install ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --namespace nginx --create-namespace
```
# Installing Minio
Now we will perform Minio installation outside of K3s. Minio will provide S3 object storage which will be used as external repository to export Kasten backups.
```console
wget https://dl.min.io/server/minio/release/linux-amd64/minio -P /root
chmod +x /root/minio
mv /root/minio /usr/local/bin
mkdir /minio
MINIO_ROOT_USER=$username MINIO_ROOT_PASSWORD=$password minio server /minio --console-address ":9001" &
echo "@reboot MINIO_ROOT_USER=$username MINIO_ROOT_PASSWORD=$password minio server /minio --console-address ":9001"" > /root/minio_cron
crontab /root/minio_cron
get_ip=$(hostname -I | awk '{print $1}')
chmod +x $HOME/minio-binaries/mc
export PATH=$PATH:$HOME/minio-binaries/
curl https://dl.min.io/client/mc/release/linux-amd64/mc \
  --create-dirs \
  -o $HOME/minio-binaries/mc

chmod +x $HOME/minio-binaries/mc
export PATH=$PATH:$HOME/minio-binaries/
mc alias set my-minio http://127.0.0.1:9000 $username $password
```
## (Optional) Buckets creation
With the commands below, you can optionnaly create some buckets we will use and configure in Kasten automatically, let's start by creating a my-minio alias :
```console
mc alias set my-minio http://127.0.0.1:9000 $username $password
```
We will create now a standard S3 bucket:
```console
mc mb my-minio/s3-standard
```
And an immutable bucket:
```console
mc mb --with-lock my-minio/s3-immutable
mc retention set --default COMPLIANCE "180d" my-minio/s3-immutable
```
# Kasten installation
This is actually my favourite part!
## Add and update Helm repository
```console
helm repo add kasten https://charts.kasten.io
helm repo update
```
## Running pre-flight checks
Running pre-flight checks (also referred as primer) is a way to enure that you'll be able install properly Kasten on your environment:
```console
curl https://docs.kasten.io/tools/k10_primer.sh | bash
```
Pay attention to the output in order to fix any problem before proceeding to Kasten installation.

## Create the namespace for Kasten
```console
kubectl create ns kasten-io
```
## Install Kasten
Kasten will be installed in the kasten-io namespace with basic authentication:
```console
helm install k10 kasten/k10 --namespace kasten-io --set "auth.basicAuth.enabled=true" --set auth.basicAuth.htpasswd=$htpasswd
```
Other Helm options are available here: https://docs.kasten.io/latest/install/advanced.html?highlight=advanced#complete-list-of-k10-helm-options

We will now find the Kasten gateway pod name and expose it:
```console
pod=$(kubectl get po -n kasten-io |grep gateway | awk '{print $1}' )
kubectl expose po $pod -n kasten-io --type=LoadBalancer --port=8000 --name=k10-dashboard
```
And setup the Kasten ingress:
```console
echo | kubectl apply -f - << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: k10-ingress
  namespace: kasten-io
spec:
  rules:
    - host: kasten.local
      http:
        paths:
          - pathType: Prefix
            path: "/"
            backend:
              service:
                name: gateway
                port:
                  number: 8000
EOF
```
## (Optional) Pre-populate Kasten

All the optional scripts belows are intended to automate and pre-populate Kasten in order to quickly deploy everything you need. 

You can also use them as an example for your future deployments and industrialize things, but keep in mind that everything can be managed **directly and easily in the web GUI of Kasten**.
### Accept EULA
```console
echo | kubectl apply -f - << EOF
apiVersion: v1
data:
  accepted: "true"
  company: Kasten
  email: my_email@mybigcompany.fr
kind: ConfigMap
metadata:
  name: k10-eula-info
  namespace: kasten-io
EOF
```
### Create location profiles in Kasten
#### Create the Minio access key and secret
##### Create Minio access key
```console
minio_access_key_id=$(echo $username)
minio_access_key_secret=$(echo $password)
```
##### Create Minio secret for K10
```console
kubectl create secret generic k10-s3-secret-minio \
      --namespace kasten-io \
      --type secrets.kanister.io/aws \
      --from-literal=aws_access_key_id=$minio_access_key_id\
      --from-literal=aws_secret_access_key=$minio_access_key_secret
```
#### Create Location profile for Minio standard bucket
```console
echo | kubectl apply -f - << EOF
echo | kubectl apply -f - << EOF
apiVersion: config.kio.kasten.io/v1alpha1
kind: Profile
metadata:
  name: s3-standard-bucket
  namespace: kasten-io
spec:
  locationSpec:
    objectStore:
      objectStoreType: S3
      name: s3-standard
      region: eu
      endpoint: http://$get_ip:9000
      skipSSLVerify: true
    type: ObjectStore
  type: Location
EOF
```

#### Create Location profile for Minio immutable bucket
```console
echo | kubectl apply -f - << EOF
apiVersion: config.kio.kasten.io/v1alpha1
kind: Profile
metadata:
  name: s3-immutable-bucket
  namespace: kasten-io
spec:
  locationSpec:
    objectStore:
      objectStoreType: S3
      name: s3-standard
      region: eu
      endpoint: http://$get_ip:9000
      skipSSLVerify: true
      protectionPeriod: 2160h
    type: ObjectStore
  type: Location
EOF
```

### Enable Kasten daily reports
```console
echo | kubectl apply -f - << EOF
kind: Policy
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: k10-system-reports-policy
  namespace: kasten-io
  managedFields:
    - manager: controllermanager-server
      operation: Update
      apiVersion: config.kio.kasten.io/v1alpha1
      fieldsType: FieldsV1
      fieldsV1:
        f:status:
          f:hash: {}
          f:specModifiedTime: {}
          f:validation: {}
    - manager: dashboardbff-server
      operation: Update
      apiVersion: config.kio.kasten.io/v1alpha1
      fieldsType: FieldsV1
      fieldsV1:
        f:spec:
          .: {}
          f:actions: {}
          f:comment: {}
          f:createdBy: {}
          f:frequency: {}
          f:lastModifyHash: {}
          f:selector: {}
        f:status: {}
spec:
  comment: The policy for enabling auto-generated reports.
  frequency: "@daily"
  selector: {}
  actions:
    - action: report
      reportParameters:
        statsIntervalDays: 1
EOF
```
# (Optional) Install Pacman application
You can now install an application to test Kasten backup/restore operations. We will use a simple pacman game application which contains also a MongoDB.
```console
helm repo add pacman https://shuguet.github.io/pacman/
helm install pacman pacman/pacman -n pacman --create-namespace --set ingress.create=true --set spec.IngresClassName=nginx
```
This application will be exposed on the web on port 80 of your server.
## Create a daily backup policy for pacman
This policy will create a dayly backup of pacman in crash consistent mode. Kasten is also able to manage application consistent backup with the use of blueprints (pre-snapshot and post- snapshot hooks) but this is not detailed (useful) in this example.
```console
echo | kubectl apply -f - << EOF
apiVersion: config.kio.kasten.io/v1alpha1
kind: Policy
metadata:
  name: pacman-backup-policy
  namespace: kasten-io
spec:
  frequency: '@daily'
  retention:
    daily: 7
  selector:
    matchExpressions:
      - key: k10.kasten.io/appNamespace
        operator: In
        values:
          - pacman
  actions:
  - action: backup
  - action: export
    exportParameters:
      frequency: "@daily"
      profile:
        name: minio-profile-standard
        namespace: kasten-io
      exportData:
        enabled: true
    retention: {}
  
EOF
```
# Final stage
We will now save all credentials and URLs in a file for further reference and clean up
```console
cat <<EOF > credentials
Kasten k10 can be accessed on http://$get_ip:8000/k10/#/ using credentials ($username/$password)
Minio console is available on  http://$get_ip:9001, with the same username/password.
    Minio has been configured with 2 buckets and according location profiles have been created in Kasten::
        - s3-standard
        - s3-immutable (compliance 180 days)
    Both of them can be accessed through API on http://$get_ip:9000 using credentials ($username/$password)
Pacman is available on http://$get_ip
EOF
rm get_helm.sh
rm k10primer.yaml
clear
echo ""
echo "Congratulations"
echo "You can now use Kasten and all its features!"
echo "Kasten k10 can be accessed on http://$get_ip:8000/k10/#/ using credentials ($username/$password)."
echo "Minio console is available on  http://$get_ip:9001, with the same username/password."
echo "    Minio has been configured with 2 buckets and according location profiles have been created in Kasten:"
echo "        - s3-standard"
echo "        - s3-immutable (compliance 180 days)"
echo "    Both of them can be accessed through API on http://$get_ip:9000 using credentials ($username/$password)"
echo "Pacman is available on http://$get_ip".
echo ""
echo "NOTE: All these informations are stored in the "credentials" file in this directory."
echo ""
echo "Have fun!"
echo ""
sleep 4
```
# One more thing...
If you're already fed up with the idea to spend time to copy/paste instructions, just run the command below as superuser (sudo su), it will take roughly 10 min to set up everything (interactive), but not sure you'll learn something (you'll need however to do the fdisk part manually before running this script):
```console
curl -s https://raw.githubusercontent.com/cpouthier/tutorial/main/installscript.sh | bash
```