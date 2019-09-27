#!/bin/bash


k="kubectl"
ns="test-$RANDOM"

echo "Using NS $ns"
$k create ns $ns


echo "Creating a ReadWriteMany volume"
$k create -n $ns -f- <<END
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: shared-vol
  labels:
    storageos.com/replicas: "1"
  annotations:
    volume.beta.kubernetes.io/storage-class: "fast"
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
END


echo "Creating NginX deployment"
$k create -n $ns -f- <<END
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
spec:
  replicas: 4
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: arau/tools:nginx-fio
        ports:
        - containerPort: 80
        volumeMounts:
        - name: docroot
          mountPath: /usr/share/nginx/html
      volumes:
      - name: docroot
        persistentVolumeClaim:
          claimName: shared-vol
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  labels:
    app: nginx
spec:
   selector:
    app: nginx
   ports:
   - name: nginx
     port: 80
     targetPort: 80
END

sleep 50

index=/usr/share/nginx/html/index.html

while true; do
    pods="$( $k get pod -n $ns --no-headers -ocustom-columns=_:.metadata.name -lapp=nginx )"
    counter=0
    for p in $pods; do
        echo "Writting dates every second in $p"
        $k -n $ns exec $p -- /bin/bash -c "index=$index; c=0; while [ \$c -lt 100  ]; do date | tee -a \$index;  echo \"<br>\" |tee -a \$index; sleep 1; (( ++\$c  )); done"
        sleep ``10
        (( ++counter ))
    done

    $k -n $ns exec $pod -- cat $index
    sleep 60
done
