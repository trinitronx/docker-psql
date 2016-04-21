returnpath/psql
===============

A basic container with `psql`, the PostgreSQL Command Line Client installed.

Building
========

This project includes a `Makefile` with targets to build & ship the container.

    make build  # to build
    make ship   # to build & push to Docker Hub (you must be a maintainer for permissions)

Running
=======

## Docker

To run the pod in Docker:

    docker run --rm -ti \
      -e PGUSER=your_db_user \
      -e PGPASSWORD=your_db_password \
      -e PGDATABASE=your_db_name \
      -e PGHOST=your_db_host \
      -e PGPORT=5432 \
    returnpath/psql -c '\dS'

## Kubernetes

To run a test pod in Kubernetes via a ReplicationController, first create a Secret containing your `base64` encoded database credentials: `db-secret.yml`

    apiVersion: v1
    kind: Secret
    metadata:
      name: db-secret-name
      labels:
        environment: prod
    type: Opaque
    data:
      pguser: <PGUSER>
      pgpassword: <PGPASSWORD>
      pgdatabase: <PGDATABASE>
      pghost: <PGHOST>
      pgport: <PGPORT>

To encode your credentials:

 - Run: `echo -n 'your-pg-user' | base64`
 - Paste in the result into the `db-secret.yml` in place of `<PGUSER>`
 - Repeat for all the other variables
 - Create the secret into the Kubernetes cluster: `kubectl apply -f db-secret.yml`

Then, create a file `psql-rc-test.yaml` containing:

    apiVersion: v1
    kind: ReplicationController
    metadata:
      name: psql
    spec:
      replicas: 1
      selector:
        name: psql-test
      template:
        metadata:
          labels:
            name: psql-test
            service: psql-test
        spec:
          containers:
          - name: psql-test
            image: returnpath/psql
            env:
            - name: PGUSER
              valueFrom:
                secretKeyRef:
                  name: db-secret-name
                  key: pguser
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-secret-name
                  key: pgpassword
            - name: PGDATABASE
              valueFrom:
                secretKeyRef:
                  name: db-secret-name
                  key: pgdatabase
            - name: PGHOST
              valueFrom:
                secretKeyRef:
                  name: db-secret-name
                  key: pghost
            - name: PGPORT
              valueFrom:
                secretKeyRef:
                  name: db-secret-name
                  key: pgport
            args:
              - "-c"
              - "\\dS"
          restartPolicy: Always

Then run:

    kubectl apply -f psql-rc-test.yaml

A Pod & ReplicationController should start and run the command: `psql -c \dS`

The above example is only truly useful as a test for whether this pod & your database connection is working.  In order to make practical use of this container, you probably want to run it with queries as scheduled jobs.

Until Kubernetes `1.3`, the `ScheduledJob` construct did not exist.  If you are using a version of Kubernetes without `ScheduledJob`, you probably want to check out: [ReturnPath/job-runner][returnpath-job-runner].

In order to use the job runner, you should use the `kubernetes-native` Job Runner.  The [job-runner's][returnpath-job-runner] `ONBUILD` instructions will copy `cron`, `defaults`, `jobs` and `k8s-jobs` directories into your image which is based on it.  

First, create a Docker image based on `returnpath/job-runner` to contain your job definitions:

`Dockerfile`:

    FROM returnpath/job-runner

Create a directory `k8s-jobs/`, then place native Kubernetes Job `.yaml` files in it.  An example for using this `psql` container might be:

`mkdir k8s-jobs/`
`k8s-jobs/psql-test.yaml`:

    apiVersion: batch/v1
    kind: Job
    metadata:
      name: psql-test
    spec:
      template:
        metadata:
          name: psql-test
          labels:
            service: psql-test
        spec:
          containers:
            - name: psql-test
              image: returnpath/psql
              args: [ "-c", "\\dS" ]
              env:
                - name: PGUSER
                  valueFrom:
                    secretKeyRef:
                      name: db-secret-name
                      key: pguser
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: db-secret-name
                      key: pgpassword
                - name: PGDATABASE
                  valueFrom:
                    secretKeyRef:
                      name: db-secret-name
                      key: pgdatabase
                - name: PGHOST
                  valueFrom:
                    secretKeyRef:
                      name: db-secret-name
                      key: pghost
                - name: PGPORT
                  valueFrom:
                    secretKeyRef:
                      name: db-secret-name
                      key: pgport
          restartPolicy: Never

Then, create a [`crond` style][cron-wikipedia] schedule for the job by creating a directory named `cron/` with a file with the **same name** as your job, passing your job name as the first argument to `/app/processor/runner`.  For example, to run it every `5` minutes:

    mkdir -p cron/
    echo "*/5 * * * * root /app/processor/runner psql-test >> /var/log/cron.log 2>&1" > cron/psql-test

Next, build your job container with:

    docker build -t your-dockerhub-username/test-jobs .
    docker push your-dockerhub-username/test-jobs

Finally, start the job-runner container you have just built on the cluster.  For example, to run `1` instance of the job-runner via a ReplicationController, create a file:

`job-runner.yaml`:

    apiVersion: v1
    kind: ReplicationController
    metadata:
      name: job-runner
    spec:
      replicas: 1
      selector:
        name: job-runner
      template:
        metadata:
          labels:
            name: job-runner
        spec:
          containers:
          - name: job-runner
            image: your-dockerhub-username/test-jobs
            env:
            - name: RUNNER
              value: kubernetes-native
            - name: KUBERNETES_MASTER
              value: https://kubernetes:443

    kubectl apply -f job-runner.yaml

Note: If you wish to run multiple instances of the `job-runner`, you will need to use the "Distributed Locking" feature of the base container.  This involves installing Consul, and is a bit more complicated than this README will delve into.

If all went well, you should now have a test job scheduled to run every 5 minutes.  To see the jobs & pods:

    kubectl get pods -l name=job-runner
    kubectl describe rc,pod -l name=job-runner
    kubectl get jobs -l service=psql-test
    kubectl get pods -l service=psql-test
    kubectl describe jobs,pods -l service=psql-test

[returnpath-job-runner]: https://github.com/ReturnPath/job-runner
[cron-wikipedia]: https://en.wikipedia.org/wiki/Cron#Configuration_file
