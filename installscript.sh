#! /bin/bash
# This script will setup all you need to create a functionnal environement to try Veeam Kasten
#   Setup apt and tune the environment
#   Setup username, password, drive path and other environement variables for further reference
#   Install Helm
#   Install K3s without Traeffik
#   Tune bash for kubectl command for autocompletion
#   Install Minio and create one standard bucket and one immutable bucket
#   Install zfs and configure a pool then configure the storage class in K3s
#   Install NGINX
#   Install Kasten K10 and expose the dashboard over HTTPS (nginx-ingress + cert-manager + Let's Encrypt)
#   Create one location profile for each Minio bucket
#   Install S3UI (a web UI for Minio) and expose it over HTTPS
#   (Optional) Install the Addressbook demo app (name+address form on a 1Gi PVC) and expose it over HTTPS
#
# Set the ubuntu service restart under apt to automatic
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
echo -e "\033[0;31m Enter partition path of extra volume (ie /dev/sdbx) to set up Kasten K10 zfs pool: \e[0m"
read DRIVE < /dev/tty
echo -e "\033[0;31m Enter name of this cluster: \e[0m"
read cluster_name < /dev/tty
echo -e "\033[0;31m Customize the name you would like to use for the storage class: \e[0m"
read sc_name < /dev/tty
echo -e "\033[0;31m Enter an email address (used for Let's Encrypt expiry notices and the Kasten EULA): \e[0m"
read admin_email < /dev/tty
echo -e "\033[0;31m (Optional) Deploy the Addressbook demo app too? A minimal name+address form backed by a 1Gi PVC, handy to test Kasten backup/restore on a small stateful app (y/n): \e[0m"
read deploy_addressbook < /dev/tty
echo ""

# Install Helm
clear
echo "Installing Helm..."
sleep 2
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x ./get_helm.sh
./get_helm.sh
echo ""
echo -e "\033[0;32m Helm installed!\e[0m"
sleep 5

#Install Kubectl for Linux AMD64
clear
echo "Installing kubectl for Linux AMD64"
sleep 2
curl -LO https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
# Adding kubectl autocompletion to bash
echo 'source <(kubectl completion bash)' >>~/.bashrc
source <(kubectl completion bash)
echo "alias k=kubectl" | tee -a /root/.bashrc
#alias k=kubectl
#insert below in .bashrc to facilitate further manipulation (WIP)
#echo "kctx () {kubectl config set-context --current --namespace=\$1}" | tee -a .bashrc /root/.bashrc
echo -e "\033[0;32m Kubectl installed!\e[0m"
sleep 5

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
echo -e "\033[0;32m k3s installed! \e[0m"
sleep 5


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
if [ -z "$get_ip" ]; then
  echo -e "\033[0;31m ERROR: could not detect this machine's IP address (hostname -I returned nothing) — check networking and re-run this script.\e[0m"
  exit 1
fi
curl -L https://dl.min.io/client/mc/release/linux-amd64/mc \
  --create-dirs \
  -o $HOME/minio-binaries/mc
chmod +x $HOME/minio-binaries/mc
export PATH=$PATH:$HOME/minio-binaries/

# A bad download (e.g. a redirect page saved instead of the real binary)
# fails silently here otherwise, leaving the "my-minio" alias never created
# and every `mc` command below failing without a clear reason.
if ! $HOME/minio-binaries/mc --version >/dev/null 2>&1; then
  echo -e "\033[0;31m ERROR: the downloaded mc binary isn't valid — check your network/proxy and re-run this script.\e[0m"
  exit 1
fi

mc alias set my-minio http://127.0.0.1:9000 $username $password

#Create standard S3 bucket
mc mb my-minio/s3-standard-$cluster_name
echo ""
echo -e "\033[0;32m Minio installed and configured with 1 bucket!\e[0m"
sleep 2

# Install zfs and configure kasten-pool storage pool on associated drive
clear
echo "Installing zfs on $DRIVE"
sleep 2
apt install zfsutils-linux open-iscsi jq -y
if ! zpool create kasten-pool "$DRIVE"; then
  echo -e "\033[0;31m ERROR: zpool create failed on $DRIVE — check the drive path (fdisk -l above) and re-run this script.\e[0m"
  exit 1
fi

# Configure zfs storage class
kubectl apply -f https://openebs.github.io/charts/zfs-operator.yaml
echo "Waiting for the ZFS CSI driver pods to be ready..."
kubectl wait --for=condition=ready pod -l app=openebs-zfs-controller -n kube-system --timeout=120s
kubectl wait --for=condition=ready pod -l app=openebs-zfs-node -n kube-system --timeout=120s
echo | kubectl apply -f - << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $sc_name
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
  name: $sc_name-zfs-snapclass
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: "true"
    k10.kasten.io/is-snapshot-class: "true"
driver: zfs.csi.openebs.io
deletionPolicy: Delete
EOF

kubectl patch storageclass $sc_name -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
echo ""
echo "ZFS installed and configured with proper annotation!"
sleep 2

#Install NGINX
clear 
echo "Installing NGINX"
sleep 2
helm upgrade --install ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --namespace nginx --create-namespace
echo ""
echo -e "\033[0;32m NGINX installed!\e[0m"
sleep 2

# Install Kasten K10
clear
echo "Installing Veeam Kasten"
sleep 2
# Adding and updating Helm repository
helm repo add kasten https://charts.kasten.io
helm repo update
# Run Kasten k10 primer (optional)
#curl https://docs.kasten.io/tools/k10_primer.sh | bash
#echo "Please exit this script within the next 15sec to fix any error before installing Kasten K10."
#sleep 15
# Create kasten-io namespace
kubectl create ns kasten-io
# Install Kasten in the kasten-io namespace with basic authentication
helm install k10 kasten/k10 --namespace kasten-io --set "auth.basicAuth.enabled=true" --set auth.basicAuth.htpasswd=$htpasswd
echo ""
echo "Waiting for all Kasten pods to be ready..."
echo -e "\033[0;31m ********** DO NOT EXIT THIS SCRIPT **********\e[0m"
# helm install returns before the pods actually exist yet — wait for at
# least one to show up first, otherwise `kubectl wait --all` below would
# match zero pods and return immediately without really waiting.
until [ "$(kubectl get pods -n kasten-io --no-headers 2>/dev/null | wc -l)" -gt 0 ]; do
  sleep 2
done
kubectl wait --for=condition=ready pod --all -n kasten-io --timeout=600s
echo ""

# Kasten's auth cookie has the Secure flag, so login only works over real
# HTTPS — plain-HTTP access via a LoadBalancer on :8000 causes an infinite
# auth redirect loop (basic-auth succeeds, but the session cookie is never
# stored/sent back). Terminate TLS via nginx-ingress with a real Let's
# Encrypt certificate (cert-manager), using a nip.io hostname so it's
# reachable from any machine, anywhere — no domain to buy, no /etc/hosts
# entry to add on every client.
echo "Setting up HTTPS access via nginx-ingress + Let's Encrypt (cert-manager)..."

nip_host="kasten.$(echo $get_ip | tr '.' '-').nip.io"

# Install cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true
kubectl -n cert-manager rollout status deployment/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=180s

# Let's Encrypt ClusterIssuer (HTTP-01 challenge, served through nginx)
echo | kubectl apply -f - << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $admin_email
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF

# Kasten's Helm chart ships a "default-deny" NetworkPolicy for its own
# namespace (security hardening). cert-manager's HTTP-01 solver pod gets
# created in this same namespace (since that's where the Ingress below
# lives), so it inherits that deny and its challenge gets silently blocked
# unless explicitly allowed — without this, the certificate request hangs
# in "pending" forever with a "connection refused" on the solver pod.
echo | kubectl apply -f - << EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-cert-manager-http01-solver
  namespace: kasten-io
spec:
  podSelector:
    matchLabels:
      acme.cert-manager.io/http01-solver: "true"
  policyTypes:
    - Ingress
  ingress:
    - {}
EOF

# Setting up Kasten k10 ingress: real nip.io hostname, reachable from
# anywhere with no client-side DNS/hosts configuration.
echo | kubectl apply -f - << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: k10-ingress
  namespace: kasten-io
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - $nip_host
      secretName: kasten-tls-letsencrypt
  rules:
    - host: $nip_host
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

echo "Waiting for Let's Encrypt to issue the certificate (can take 1-2 minutes)..."
for i in $(seq 1 30); do
  kubectl -n kasten-io get secret kasten-tls-letsencrypt >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n kasten-io get certificate kasten-tls-letsencrypt

#Accept EULA
echo | kubectl apply -f - << EOF
apiVersion: v1
data:
  accepted: "true"
  company: MyBigCompany
  email: $admin_email
kind: ConfigMap
metadata:
  name: k10-eula-info
  namespace: kasten-io
EOF
clear

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
  name: s3-standard-bucket-$cluster_name
  namespace: kasten-io
spec:
  locationSpec:
    objectStore:
      objectStoreType: S3
      name: s3-standard-$cluster_name
      region: eu
      endpoint: http://$get_ip:9000
      skipSSLVerify: true
    type: ObjectStore
    credential:
      secretType: AwsAccessKey
      secret:
        apiVersion: v1
        kind: Secret
        name: k10-s3-secret-minio
        namespace: kasten-io
  type: Location
EOF


echo ""
echo -e "\033[0;32m Veeam Kasten is now installed\e[0m"
sleep 2

# Install S3UI (a small web UI for Minio) and expose it over HTTPS
clear
echo "Installing S3UI"
sleep 2

s3ui_nip_host="s3ui.$(echo $get_ip | tr '.' '-').nip.io"

# Namespace + Deployment + Service + Ingress for s3ui, reusing the same
# nginx-ingress + cert-manager + letsencrypt-prod ClusterIssuer already set
# up for Kasten above (ClusterIssuers aren't namespaced, so no need to
# recreate one here).
echo | kubectl apply -f - << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: s3ui
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: s3ui
  namespace: s3ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: s3ui
  template:
    metadata:
      labels:
        app: s3ui
    spec:
      containers:
        - name: s3ui
          image: cpouthier/s3ui:latest
          imagePullPolicy: Always
          ports:
            - containerPort: 8000
          envFrom:
            - secretRef:
                name: s3ui-config
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 15
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: s3ui
  namespace: s3ui
spec:
  selector:
    app: s3ui
  ports:
    - port: 80
      targetPort: 8000
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: s3ui-ingress
  namespace: s3ui
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - $s3ui_nip_host
      secretName: s3ui-tls-letsencrypt
  rules:
    - host: $s3ui_nip_host
      http:
        paths:
          - pathType: Prefix
            path: "/"
            backend:
              service:
                name: s3ui
                port:
                  number: 80
EOF

# Reuse the same Minio credentials already used for Kasten's location
# profile above ($minio_access_key_id / $minio_access_key_secret) — single
# source of truth, nothing to duplicate by hand.
kubectl create secret generic s3ui-config -n s3ui \
  --from-literal=MINIO_ENDPOINT="${get_ip}:9000" \
  --from-literal=MINIO_ACCESS_KEY="${minio_access_key_id}" \
  --from-literal=MINIO_SECRET_KEY="${minio_access_key_secret}" \
  --from-literal=MINIO_SECURE=false \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n s3ui rollout restart deployment/s3ui
kubectl -n s3ui rollout status deployment/s3ui --timeout=120s

echo "Waiting for the Let's Encrypt certificate for S3UI (can take 1-2 minutes)..."
for i in $(seq 1 30); do
  kubectl -n s3ui get secret s3ui-tls-letsencrypt >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n s3ui get certificate

echo ""
echo -e "\033[0;32m S3UI installed!\e[0m"
sleep 2

# (Optional) Install the Addressbook demo app — a minimal name+address form
# backed by a 1Gi PVC, good for trying out Kasten backup/restore on a small
# stateful app without the moving parts of a full database Deployment.
if [[ "$deploy_addressbook" =~ ^[Yy]$ ]]; then
  clear
  echo "Installing Addressbook"
  sleep 2

  addressbook_nip_host="addressbook.$(echo $get_ip | tr '.' '-').nip.io"

  # Namespace + PVC + Deployment + Service + Ingress, reusing the same
  # nginx-ingress + cert-manager + letsencrypt-prod ClusterIssuer already set
  # up for Kasten above. The "database" is a single SQLite file on the PVC —
  # no separate DB Deployment/Service/Secret needed.
  echo | kubectl apply -f - << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: addressbook
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: addressbook-data
  namespace: addressbook
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: $sc_name
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: addressbook
  namespace: addressbook
spec:
  # Recreate, not the default RollingUpdate: the PVC is ReadWriteOnce, so a
  # second pod can't mount it until the first one releases it — RollingUpdate
  # would leave a new pod stuck Pending on volume attach forever.
  strategy:
    type: Recreate
  replicas: 1
  selector:
    matchLabels:
      app: addressbook
  template:
    metadata:
      labels:
        app: addressbook
    spec:
      containers:
        - name: addressbook
          image: cpouthier/addressbook:latest
          imagePullPolicy: Always
          ports:
            - containerPort: 8000
          env:
            - name: DB_PATH
              value: /data/addressbook.db
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /ready
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 15
            periodSeconds: 30
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: addressbook-data
---
apiVersion: v1
kind: Service
metadata:
  name: addressbook
  namespace: addressbook
spec:
  selector:
    app: addressbook
  ports:
    - port: 80
      targetPort: 8000
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: addressbook-ingress
  namespace: addressbook
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - $addressbook_nip_host
      secretName: addressbook-tls-letsencrypt
  rules:
    - host: $addressbook_nip_host
      http:
        paths:
          - pathType: Prefix
            path: "/"
            backend:
              service:
                name: addressbook
                port:
                  number: 80
EOF

  kubectl -n addressbook rollout status deployment/addressbook --timeout=120s

  echo "Waiting for the Let's Encrypt certificate for Addressbook (can take 1-2 minutes)..."
  for i in $(seq 1 30); do
    kubectl -n addressbook get secret addressbook-tls-letsencrypt >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl -n addressbook get certificate

  echo ""
  echo -e "\033[0;32m Addressbook installed!\e[0m"
  sleep 2
fi

# Save credentials and URLs for further reference
cat <<EOF > credentials
Kasten k10 can be accessed on https://$nip_host/k10/#/ using credentials ($username/$password)
Minio console is available on  http://$get_ip:9001, with the same username/password.
    Minio has been configured with 1 bucket and according location profile has been created in Kasten:
        - s3-standard
    It can be accessed through API on http://$get_ip:9000 using credentials ($username/$password)
S3UI (a web UI for Minio) can be accessed on https://$s3ui_nip_host using the same credentials ($username/$password)
Your storage class name is $sc_name on this cluster $cluster_name.
EOF
if [[ "$deploy_addressbook" =~ ^[Yy]$ ]]; then
  echo "Addressbook (demo app) is accessible at https://$addressbook_nip_host" >> credentials
fi
# Finish
rm get_helm.sh
clear
echo ""
echo ""
echo -e "\033[0;32m Congratulations\e[0m"
echo -e "\033[0;32m You can now use Veeam Kasten and all its features!\e[0m"
echo ""
echo ""
echo "Kasten k10 can be accessed on https://$nip_host/k10/#/ using credentials ($username/$password)."
echo "Minio console is available on  http://$get_ip:9001, with the same username/password."
echo "    Minio has been configured with 1 bucket and according location profile has been created in Kasten:"
echo "        - s3-standard"
echo "    It can be accessed through API on http://$get_ip:9000 using credentials ($username/$password)"
echo "S3UI (a web UI for Minio) can be accessed on https://$s3ui_nip_host using the same credentials ($username/$password)"
if [[ "$deploy_addressbook" =~ ^[Yy]$ ]]; then
  echo "Addressbook (demo app) is accessible at https://$addressbook_nip_host"
fi
echo "Your storage class name is $sc_name on this cluster $cluster_name"

echo "NOTE: All these informations are stored in the "credentials" file in this directory."
echo ""
echo "Have fun!"
echo ""
sleep 4
exit
