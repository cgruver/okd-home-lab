SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
EDGE=false
INDEX=""
CONFIG_FILE=${LAB_CONFIG_FILE}

for i in "$@"
do
  case ${i} in
    -i|--init)
      INIT=true
      shift
    ;;
    -n|--nexus)
      INIT=true
      shift
    ;;
    -g|--gitea)
      INIT=true
      shift
    ;;
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    *)
          echo "USAGE: configPi.sh [-i|--init] [-c|--config=path/to/config/file] [-n|--nexus] [-g|--gitea]"
    ;;
  esac
done

if [[ ${CONFIG_FILE} == "" ]]
then
echo "You must specify a lab configuration YAML file."
exit 1
fi
