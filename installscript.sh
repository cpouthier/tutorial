#! /bin/bash
# This script will:
#   Setup apt and tune the environment
#   Setup username, password and drive path as environement variables for further reference
#   Install Helm
#   Install K3s without Traeffik
#   Tune bash for kubectl command for autocompletion
#   Install Minio and create one standard bucket and one immutable bucket
#   Install zfs and configure a pool then configure the storage class in K3s
#   Install NGINX
#   Install Kasten K10 and expose dashboard
#   Create one location profile for each Minio bucket
#   Install Pacman app and expose it on port 80
#   Set up a daily backup and export policy for Pacman
# 
# The following script will set the ubuntu service restart under apt to automatic
clear
sed -i 's/#$nrconf{restart} = '"'"'i'"'"';/$nrconf{restart} = '"'"'a'"'"';/g' /etc/needrestart/needrestart.conf
apt update
sysctl fs.inotify.max_user_watches=524288
sysctl fs.inotify.max_user_instances=512
echo "fs.inotify.max_user_watches = 524288" >> /etc/sysctl.conf
echo "fs.inotify.max_user_instances = 512" >> /etc/sysctl.conf
# Installing apache2-utils to get htpasswd
apt install apache2-utils -y
clear
# Setting up interactively some environment variables to run this script
echo "Kasten will be installed with basic authentication, hence the need to provide a username and a password."
echo "You will use also those credentials to connect to Minio."
echo -e "\033[0;31m Enter the username: \e[0m"
read username < /dev/tty
echo -e "\033[0;31m Enter the password: \e[0m"
read password < /dev/tty
htpasswd_entry=$(htpasswd -nbm "$username" "$password" | cut -d ":" -f 2)
htpasswd="$username:$htpasswd_entry"
echo "Successfully generated htpasswd entry: $htpasswd"
sleep 3
fdisk -l
echo ""
echo -e "\033[0;31m Enter drive path of extra volume (ie /dev/sdb) to set up Kasten K10 zfs pool: \e[0m"
read DRIVE < /dev/tty

# Install Helm
clear
echo "Installing Helm..."
sleep 2
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x ./get_helm.sh
./get_helm.sh
echo ""
echo "Helm installed!"
sleep 2

#Install Kubectl for Linux AMD64
clear
echo "Installing kubectl"
sleep 2
curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
# Adding kubectl autocompletion to bash
echo 'source <(kubectl completion bash)' >>~/.bashrc
source <(kubectl completion bash)
echo "alias k=kubectl" | tee -a .bashrc /root/.bashrc
alias k=kubectl
echo ""
echo "Kubectl installed!"
sleep 2

# Installing k3s single node cluster with local storage disabled 
clear
echo "Installing k3s"
sleep 2
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable local-storage --disable=traefik" sh -s -
mkdir /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
chmod 600 ~/.kube/config && export KUBECONFIG=~/.kube/config
# Checking k3s installation
echo ""
echo "Please wait 30s for k3s to spin up..."
sleep 30
k3s check-config
kubectl cluster-info
kubectl get nodes -o wide
echo ""
echo -e "\033[0;31m k3s installed, please review k3s information whitin the next 15sec... \e[0m"
sleep 15


# Installing Minio for AMD64 outside K3s
clear
echo "Installing Minio"
sleep 2
echo ""
echo "The script is about to install minio for linux AMD64, please ensure you're running on this platform type, otherwise exit this script!"
echo ""
sleep 10
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

#Create standard S3 bucket
mc mb my-minio/s3-standard
#create immutable S3 bucket for compliance
mc mb --with-lock my-minio/s3-immutable
mc retention set --default COMPLIANCE "180d" my-minio/s3-immutable
echo ""
echo "Minio installed and configured with 2 buckets!"
sleep 2

# Install zfs and configure kasten-pool storage pool on associated drive
clear
echo "Installing zfs on $DRIVE"
sleep 2
apt install zfsutils-linux open-iscsi jq -y
zpool create kasten-pool $DRIVE

# Configure zfs storage class
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


kubectl patch storageclass kasten-zfs -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
echo ""
echo "ZFS installed!"
sleep 2

#Install NGINX
clear 
echo "Installing NGINX"
sleep 2
helm upgrade --install ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --namespace nginx --create-namespace
echo ""
echo "NGINX installed!"
sleep 2

# Install Kasten K10
clear
echo "Installing Kasten"
sleep 2
# Adding and updating Helm repository
helm repo add kasten https://charts.kasten.io
helm repo update
# Run Kasten k10 primer
curl https://docs.kasten.io/tools/k10_primer.sh | bash
echo "Please exit this script within the next 15sec to fix any error before installing Kasten K10."
sleep 15
# Create kasten-io namespace
kubectl create ns kasten-io
# Install Kasten in the kasten-io namespace with basic authentication
helm install k10 kasten/k10 --namespace kasten-io --set "auth.basicAuth.enabled=true" --set auth.basicAuth.htpasswd=$htpasswd
echo ""
echo "Please wait for 30sec whilst we wait for the pods to spin up..."
echo "After this period the external URL for K10 access will display (DO NOT exit this script)"
sleep 30
echo ""
# Finding the Kasten K10 gateway namespace name
pod=$(kubectl get po -n kasten-io |grep gateway | awk '{print $1}' )
# Expose the gateway pod through the load balancer on port 8000
kubectl expose po $pod -n kasten-io --type=LoadBalancer --port=8000 --name=k10-dashboard

# Setting up Kasten k10 ingress
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

#Accept EULA
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
clear
echo ""
echo "Kasten is now installed"
sleep 2

###Create Profiles in Kasten

#Create Minio access key
minio_access_key_id=$(echo $username)
minio_access_key_secret=$(echo $password)
#Create Minio secret for K10
kubectl create secret generic k10-s3-secret-minio \
      --namespace kasten-io \
      --type secrets.kanister.io/aws \
      --from-literal=aws_access_key_id=$minio_access_key_id\
      --from-literal=aws_secret_access_key=$minio_access_key_secret

#Create Location profile for Minio Standard bucket
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
    credential:
      secretType: AwsAccessKey
      secret:
        apiVersion: v1
        kind: secret
        name: k10-s3-secret-minio
        namespace: kasten-io
  type: Location
EOF


#Create Location profile for Minio Immutable bucket
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
      name: s3-immutable
      region: eu
      endpoint: http://$get_ip:9000
      skipSSLVerify: true
      protectionPeriod: 2160h
    type: ObjectStore
  credential:
    secretType: AwsAccessKey
    secret:
      apiVersion: v1
      kind: secret
      name: k10-s3-secret-minio
      namespace: kasten-io
  type: Location
EOF


# Enable Kasten daily Kasten reports
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

# Install Pacman application
clear 
echo "Installing Pacman"
sleep 2
helm repo add pacman https://shuguet.github.io/pacman/
helm install pacman pacman/pacman -n pacman --create-namespace --set ingress.create=true --set spec.IngresClassName=nginx
echo ""
echo "Pacman is now installed!"
sleep 2

# Create a Daily backup policy for pacman
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

# Save credentials and URLs for further reference
cat <<EOF > credentials
Kasten k10 can be accessed on http://$get_ip:8000/k10/#/ using credentials ($username/$password)
Minio console is available on  http://$get_ip:9001, with the same username/password.
    Minio has been configured with 2 buckets and according location profiles have been created in Kasten::
        - s3-standard
        - s3-immutable (compliance 180 days)
    Both of them can be accessed through API on http://$get_ip:9000 using credentials ($username/$password)
Pacman is available on http://$get_ip
EOF
# Finish
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
exit
