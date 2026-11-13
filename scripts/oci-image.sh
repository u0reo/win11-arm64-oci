#!/usr/bin/env bash
# Upload a qcow2 to Object Storage, import it as an OCI custom image and
# optionally launch an Ampere A1 instance from it.
#
#   ./scripts/oci-image.sh --image build/win11-arm64.qcow2 \
#       --compartment ocid1.compartment.oc1..xxxx \
#       --subnet ocid1.subnet.oc1..xxxx --launch
#
# Authentication (OCI_AUTH):
#   auto                use ~/.oci/config if present, else instance principal
#   api_key             normal ~/.oci/config profile
#   instance_principal  dynamic group policy (recommended on an A1 builder)
#
# Everything can also be set with environment variables:
#   OCI_COMPARTMENT_ID OCI_BUCKET OCI_SUBNET_ID OCI_AVAILABILITY_DOMAIN
#   OCI_OCPUS OCI_MEMORY_GB OCI_INSTANCE_NAME OCI_OS_VERSION
set -euo pipefail

IMAGE=""
DISPLAY=""
COMPARTMENT=${OCI_COMPARTMENT_ID:-}
BUCKET=${OCI_BUCKET:-win11-arm64-import}
SUBNET=${OCI_SUBNET_ID:-}
AD=${OCI_AVAILABILITY_DOMAIN:-}
OCPUS=${OCI_OCPUS:-4}
MEMGB=${OCI_MEMORY_GB:-24}
INSTANCE_NAME=${OCI_INSTANCE_NAME:-win11-arm64}
OS_VERSION=${OCI_OS_VERSION:-11}
LAUNCH=0
KEEP_OBJECT=0
DRY=0
TIMEOUT=${OCI_IMPORT_TIMEOUT:-3600}

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE=$2; shift 2 ;;
        --name) DISPLAY=$2; shift 2 ;;
        --compartment) COMPARTMENT=$2; shift 2 ;;
        --bucket) BUCKET=$2; shift 2 ;;
        --subnet) SUBNET=$2; shift 2 ;;
        --ad) AD=$2; shift 2 ;;
        --ocpus) OCPUS=$2; shift 2 ;;
        --memory) MEMGB=$2; shift 2 ;;
        --instance-name) INSTANCE_NAME=$2; shift 2 ;;
        --launch) LAUNCH=1; shift ;;
        --keep-object) KEEP_OBJECT=1; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "oci-image: unknown argument: $1" >&2; usage 1 ;;
    esac
done

[ -n "$IMAGE" ] || { echo "oci-image: --image is required" >&2; usage 1; }
[ -f "$IMAGE" ] || { echo "oci-image: missing $IMAGE" >&2; exit 1; }
[ -n "$DISPLAY" ] || DISPLAY="win11-arm64-$(date +%Y%m%d-%H%M)"

if [ "$DRY" = 0 ]; then
    command -v oci >/dev/null 2>&1 || {
        echo "oci-image: OCI CLI not found" >&2
        echo "  https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm" >&2
        exit 1
    }
    [ -n "$COMPARTMENT" ] || {
        echo "oci-image: --compartment (or OCI_COMPARTMENT_ID) is required" >&2
        exit 1
    }
fi

AUTH_MODE=${OCI_AUTH:-auto}
if [ "$AUTH_MODE" = auto ]; then
    if [ -f "${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}" ]; then
        AUTH_MODE=api_key
    else
        AUTH_MODE=instance_principal
    fi
fi
AUTH_ARGS=()
[ "$AUTH_MODE" = instance_principal ] && AUTH_ARGS=(--auth instance_principal)

OBJ=$(basename "$IMAGE")
SIZE=$(stat -c %s "$IMAGE")

echo "== plan =="
echo "  image        $IMAGE ($SIZE bytes)"
echo "  display name $DISPLAY"
echo "  bucket       $BUCKET (object $OBJ)"
echo "  auth         $AUTH_MODE"
echo "  launch       $([ "$LAUNCH" = 1 ] && echo yes || echo no)"
echo "  os version   Windows $OS_VERSION"
echo
echo "NOTE: OCI documents custom image import for Windows Server only."
echo "      Windows 11 ARM64 is not on the supported list.  The import may"
echo "      succeed but Oracle will not support the result, and you must"
echo "      comply with your own Microsoft licence."
echo

if [ "$DRY" = 1 ]; then
    cat <<EOF
# commands that would run:
oci os ns get
oci os bucket create --name $BUCKET --compartment-id $COMPARTMENT
oci os object put --bucket-name $BUCKET --name $OBJ --file $IMAGE --force
oci compute image import from-object --compartment-id $COMPARTMENT \\
    --bucket-name $BUCKET --namespace <ns> --name $OBJ \\
    --display-name $DISPLAY --launch-mode PARAVIRTUALIZED \\
    --operating-system Windows --operating-system-version $OS_VERSION \\
    --source-image-type QCOW2
oci compute image update --image-id <id> --launch-options '{"firmware":"UEFI_64"}'
oci compute image-shape-compatibility-entry add --image-id <id> \\
    --shape-name VM.Standard.A1.Flex
oci compute instance launch --compartment-id $COMPARTMENT --shape VM.Standard.A1.Flex \\
    --shape-config '{"ocpus":$OCPUS,"memoryInGBs":$MEMGB}' --image-id <id> \\
    --subnet-id ${SUBNET:-<subnet>} --assign-public-ip true
EOF
    exit 0
fi

echo "[1/6] object storage namespace"
NS=$(oci os ns get --query data --raw-output "${AUTH_ARGS[@]}")
echo "  $NS"

echo "[2/6] bucket"
if ! oci os bucket get --namespace "$NS" --bucket-name "$BUCKET" \
        "${AUTH_ARGS[@]}" >/dev/null 2>&1; then
    oci os bucket create --namespace "$NS" --name "$BUCKET" \
        --compartment-id "$COMPARTMENT" "${AUTH_ARGS[@]}" >/dev/null
    echo "  created $BUCKET"
else
    echo "  exists $BUCKET"
fi

echo "[3/6] upload $OBJ"
echo "  this can take a while; the object is removed after the import"
oci os object put --namespace "$NS" --bucket-name "$BUCKET" \
    --name "$OBJ" --file "$IMAGE" --force "${AUTH_ARGS[@]}" >/dev/null
echo "  uploaded"

echo "[4/6] import as custom image"
IMG_ID=$(oci compute image import from-object \
    --compartment-id "$COMPARTMENT" \
    --namespace "$NS" --bucket-name "$BUCKET" --name "$OBJ" \
    --display-name "$DISPLAY" \
    --launch-mode PARAVIRTUALIZED \
    --operating-system "Windows" \
    --operating-system-version "$OS_VERSION" \
    --source-image-type QCOW2 \
    --query 'data.id' --raw-output "${AUTH_ARGS[@]}")
echo "  image id $IMG_ID"

if [ "$KEEP_OBJECT" = 0 ]; then
    oci os object delete --namespace "$NS" --bucket-name "$BUCKET" \
        --name "$OBJ" --force "${AUTH_ARGS[@]}" >/dev/null 2>&1 || true
    echo "  object deleted"
fi

echo "[5/6] wait for AVAILABLE (up to ${TIMEOUT}s)"
START=$(date +%s)
while :; do
    STATE=$(oci compute image get --image-id "$IMG_ID" \
        --query 'data."lifecycle-state"' --raw-output "${AUTH_ARGS[@]}")
    echo "  state=$STATE"
    case "$STATE" in
        AVAILABLE) break ;;
        DELETED|DISABLED)
            echo "oci-image: import failed ($STATE)" >&2
            exit 1
            ;;
    esac
    if [ $(( $(date +%s) - START )) -gt "$TIMEOUT" ]; then
        echo "oci-image: timed out waiting for the image" >&2
        exit 1
    fi
    sleep 30
done

# ARM64 has no BIOS; make the firmware explicit.
oci compute image update --image-id "$IMG_ID" \
    --launch-options '{"firmware":"UEFI_64"}' "${AUTH_ARGS[@]}" >/dev/null
oci compute image-shape-compatibility-entry add --image-id "$IMG_ID" \
    --shape-name "VM.Standard.A1.Flex" "${AUTH_ARGS[@]}" >/dev/null 2>&1 || true
echo "  launch options: UEFI_64, shape VM.Standard.A1.Flex"

echo "[6/6] launch"
if [ "$LAUNCH" = 0 ]; then
    cat <<EOF

Image is ready.  Launch it with:

  oci compute instance launch \\
    --compartment-id $COMPARTMENT \\
    --availability-domain <AD> \\
    --shape VM.Standard.A1.Flex \\
    --shape-config '{"ocpus":$OCPUS,"memoryInGBs":$MEMGB}' \\
    --image-id $IMG_ID \\
    --subnet-id <SUBNET_OCID> \\
    --assign-public-ip true \\
    --display-name $INSTANCE_NAME

Then allow TCP 3389 from your own IP only, and connect with RDP.
EOF
    exit 0
fi

[ -n "$SUBNET" ] || { echo "oci-image: --subnet is required with --launch" >&2; exit 1; }
if [ -z "$AD" ]; then
    AD=$(oci iam availability-domain list --compartment-id "$COMPARTMENT" \
        --query 'data[0].name' --raw-output "${AUTH_ARGS[@]}")
fi

INST_ID=$(oci compute instance launch \
    --compartment-id "$COMPARTMENT" \
    --availability-domain "$AD" \
    --shape "VM.Standard.A1.Flex" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMGB}" \
    --image-id "$IMG_ID" \
    --subnet-id "$SUBNET" \
    --assign-public-ip true \
    --display-name "$INSTANCE_NAME" \
    --query 'data.id' --raw-output "${AUTH_ARGS[@]}")
echo "  instance $INST_ID"

echo "  waiting for RUNNING"
for _ in $(seq 1 60); do
    ST=$(oci compute instance get --instance-id "$INST_ID" \
        --query 'data."lifecycle-state"' --raw-output "${AUTH_ARGS[@]}")
    [ "$ST" = RUNNING ] && break
    sleep 10
done

IP=$(oci compute instance list-vnics --instance-id "$INST_ID" \
    --query 'data[0]."public-ip"' --raw-output "${AUTH_ARGS[@]}" 2>/dev/null || true)
echo
echo "== ready =="
echo "  image id     $IMG_ID"
echo "  instance id  $INST_ID"
echo "  public ip    ${IP:-<none: private subnet>}"
echo
echo "Allow TCP 3389 from your IP, then:"
echo "  mstsc /v:${IP:-<ip>}:3389"
echo "  user: ${WIN_USERNAME:-User}  password: see config/defaults.env"
echo
echo "The image has NLA disabled and the firewall off.  Do not expose 3389"
echo "to 0.0.0.0/0."
