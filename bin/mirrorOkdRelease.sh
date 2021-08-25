#!/bin/bash

OKD_REGISTRY=${OKD_STABLE_REGISTRY}
NIGHTLY=false

for i in "$@"
do
case $i in
    -n|--nightly)
    NIGHTLY=true
    shift
    ;;
    *)
          # put usage here:
    ;;
esac
done

if [[ ${NIGHTLY} == "true" ]]
then
  OKD_REGISTRY=${OKD_NIGHTLY_REGISTRY}
fi

OKD_RELEASE=$(oc version --client=true | cut -d" " -f3)

oc adm -a ${LOCAL_SECRET_JSON} release mirror --from=${OKD_REGISTRY}:${OKD_RELEASE} --to=${LOCAL_REGISTRY}/${OKD_RELEASE} --to-release-image=${LOCAL_REGISTRY}/${OKD_RELEASE}:${OKD_RELEASE}

