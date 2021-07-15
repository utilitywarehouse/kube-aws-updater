#!/usr/bin/env bash

# Library to provide reporting functionality to the aws cluster rotation
#
# Assumptions:
# * rotations happen for a single role at a time
# * each role is managed by a single autoscaling group (asg)
# * if a rotation was interrupted, we always want to finish it before starting a new one
#
# Usage:
# * library should be sourced by `kube-aws-updater`
# * "public" functions the ones namespaced like 'report::my_function()'
#
# Shell style guide: https://google.github.io/styleguide/shellguide.html

set -o errexit
set -o nounset
set -o pipefail

########################################
# GLOBAL STATE
#
# Inherits from the kube-aws-updater, so no complex validation needed
########################################

readonly KUBE_CONTEXT="${kube_context:?"Error: variable 'kube_context' must be set"}"
readonly NODE_ROLE="${role:?"Error: variable 'role' must be set"}"
readonly AWS_PROFILE="${aws_profile:?"Error: variable 'aws_profile' must be set"}"
readonly SNAPSHOTS_FILE="${SNAPSHOTS_FILE:-"./snapshots.json"}"

ASG_NAME=""
ROLL_TIMESTAMP=""
RUN_TIMESTAMP=""

########################################
# REPORT FUNCTIONS
#
# Manage metadata about the report
########################################

# Initialize global state. Order is important
initialize() {
  if [ ! -f "${SNAPSHOTS_FILE}" ]; then
    echo "[]" >"${SNAPSHOTS_FILE}"
  fi

  ASG_NAME=$(get_asg_name)
  ROLL_TIMESTAMP="$(get_ongoing_roll_timestamp)" # ISO8601 UTC
  RUN_TIMESTAMP=$(make_snapshot)                 # ISO8601 UTC
}

get_global_state() {
  echo "KUBE_CONTEXT(ro): ${KUBE_CONTEXT}"
  echo "NODE_ROLE(ro): ${NODE_ROLE}"
  echo "AWS_PROFILE(ro): ${AWS_PROFILE}"
  echo "SNAPSHOTS_FILE(ro): ${SNAPSHOTS_FILE}"
  echo "ASG_NAME: ${ASG_NAME}"
  echo "ROLL_TIMESTAMP: ${ROLL_TIMESTAMP}"
  echo "RUN_TIMESTAMP:  ${RUN_TIMESTAMP}"
}

get_ongoing_roll_timestamp() {
  local nodes timestamp
  nodes=$(retry kubectl --context "${KUBE_CONTEXT}" get node -l "roll-timestampX" -o json)
  timestamp=$(echo "${nodes}" | jq -r '.items[0].metadata.labels."roll-timestamp" // empty') # miliseonds since epoch
  if [[ "${timestamp}" != "" ]]; then
    timestamp=$(date --utc --date "@${timestamp}" +'%Y-%m-%dT%H:%M:%SZ') # ISO8601 UTC
  fi
  echo "${timestamp}"
}

########################################
# SUPPORT FUNCTIONS
#
# Utilities not directly related with the report
########################################

# Get the current timestamp, ISO8601 UTC format
timestamp_now() {
  echo $(date --utc +'%Y-%m-%dT%H:%M:%SZ')
}

# Retry commands until they succeed
function retry() {
  local n=1
  local max=12
  local delay=8
  while true; do
    if "$@"; then
      break
    else
      if [[ $n -lt $max ]]; then
        ((n++))
        log "command failed: attempt=$n max=$max"
        sleep $delay
      else
        log "the command has failed after $n attempts"
        exit 1
      fi
    fi
  done
}

########################################

# Checks if the cluster is ongoing a roll, and sets the retiring time
get_rotation_id() {
  local nodes
  nodes=$(retry kubectl --context "${KUBE_CONTEXT}" get node -l "retiring" -o json)
  RETIRING=$(echo "${nodes}" | jq -r '.items[0].metadata.labels.retiring')
}

# Get asg name that manages the rotating node's role
get_asg_name() {
  local addresses instances asg_name
  addresses=$(retry kubectl --context "${KUBE_CONTEXT}" get node -l "role=${NODE_ROLE}" -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}' | sed 's/.$//')
  instances=$(retry aws --profile "${AWS_PROFILE}" ec2 describe-instances --max-items=1 --filters "Name=network-interface.private-dns-name,Values=${addresses}")
  asg_name=$(echo "${instances}" | jq -r '.Reservations | first | .Instances | first | .Tags[] | select(.Key == "aws:autoscaling:groupName") | .Value')
  echo "${asg_name}"
}

# Checks if the cluster is ongoing a roll, and sets the retiring time
detect_ongoing_roll() {
  local nodes
  nodes=$(retry kubectl --context "${KUBE_CONTEXT}" get node -l "retiring" -o json)
  RETIRING=$(echo "${nodes}" | jq -r '.items[0].metadata.labels.retiring')
}

# Sets the asg name that manages the rotating node's role
detect_asg_name() {
  local addresses instances
  addresses=$(retry kubectl --context "${KUBE_CONTEXT}" get node -l "role=${NODE_ROLE}" -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}' | sed 's/.$//')
  instances=$(retry aws --profile "${AWS_PROFILE}" ec2 describe-instances --max-items=1 --filters "Name=network-interface.private-dns-name,Values=${addresses}")
  #ASG_NAME=$(echo "${instances}" | jq -r '.Reservations | first | .Instances | first | .Tags[] | select(.Key == "aws:autoscaling:groupName") | .Value')
}

# Prints the list of retiring nodes in json format starting from the most recent
get_retiring_nodes() {
  local nodes
  nodes=$(retry kubectl --context "${KUBE_CONTEXT}" get node -l "role=${NODE_ROLE},retiring=${RETIRING}" -o json)
  nodes=$(parse_nodes "${nodes}")
  echo "${nodes}"
}

# Print true or false, depending on nodes being az balanced
are_nodes_az_balanced() {
  local nodes=$1
  local a_count b_count c_count
  a_count=$(echo "${nodes}" | jq '[.[] | select(.zone == "eu-west-1a")] | length')
  b_count=$(echo "${nodes}" | jq '[.[] | select(.zone == "eu-west-1b")] | length')
  c_count=$(echo "${nodes}" | jq '[.[] | select(.zone == "eu-west-1c")] | length')

  if [[ "${a_count}" == "${b_count}" ]] && [[ "${a_count}" == "${c_count}" ]]; then
    echo "true"
  else
    echo "not equal"
  fi
}

compare_snapshots() {
  # how many nodes/instances have been removed?added?
  echo "${CLUSTER_SNAPSHOT}" >snapshot.json
  cat "nodes.json" | jq '.uno - .dos'
}

summary() {
  local before=$1
  local now=$2

  before=$(jq -c '.[] | select(.timestamp == "'"${before}"'")' "${SNAPSHOTS_FILE}")
  now=$(jq -c '.[] | select(.timestamp == "'"${now}"'")' "${SNAPSHOTS_FILE}")
  data='{"before":'"${before}"',"now":'${now}'}'
  #added=$(echo "${data}" | jq '.now.nodes - .before.nodes | .[].op = "add"')
  #removed=$(echo "${data}" | jq '.before.nodes - .now.nodes')
  changes=$(echo "${data}" | jq '
    [ .now.nodes - .before.nodes | .[].op = "add" | .[] ]
    +
    [ .before.nodes - .now.nodes | .[].op = "rm" | .[] ]
  ')
  #     | sort_by(.createdAt |= fromdate) | reverse

  # TODO: note that sorting on creation timestamp has no meaning!, since it only matters on new instances (we don't know when they were removed). Step by step report has no meaning. It is better to do full reports on batches of nodes. Something like that

  #echo $added | jq '.'
  #echo $removed | jq '.'
}

#############
# DISCARDED #
#############

#report() {
#  local now nodes node_count asg instance_count
#  now=$(date +'%Y-%m-%dT%H:%M:%S')
#  nodes=$(get_nodes)
#  asg=$(get_asg)
#  node_count=$(are_nodes_az_balanced "${nodes}")
#  instance_count=$(get_az_instance_count "${asg}")
#
#  echo "AZ report at ${now}"
#  echo "Kube's Nodes:     ${node_count}"
#  echo "AWS's Instances:  ${instance_count}"
#}

#refresh_memory_snapshot() {
#  CLUSTER_SNAPSHOT='{"timestamp": "'"$(timestamp_now)"'","asg":'"$(get_asg | jq -c)"',"nodes":'"$(get_nodes | jq -c)"'}'
#}

#get_snapshot_now() {
#  echo '{"timestamp": "'"${timestamp}"'","asg":'"$(get_asg | jq -c)"',"nodes":'"$(get_nodes | jq -c)"'}'
#}

#snapshot_cluster() {
#  local timestamp snapshot tmp
#
#  if [ ! -f "${SNAPSHOTS_FILE}" ]; then
#    echo "[]" >"${SNAPSHOTS_FILE}"
#  fi
#
#  timestamp="$(timestamp_now)"
#  #snapshot='{"timestamp": "'"${timestamp}"'","asg":'"$(get_asg | jq -c)"',"nodes":'"$(get_nodes | jq -c)"'}'
#  snapshot='{"timestamp": "'"${timestamp}"'","asg":'"$(get_asg | jq -c)"',"nodes":'"$(get_nodes | jq -c)"'}'
#  tmp=$(jq -c '. + ['"${snapshot}"']' "${SNAPSHOTS_FILE}")
#  echo "${tmp}" >"${SNAPSHOTS_FILE}"
#
#  LAST_SNAPSHOT="${timestamp}"
#}

#######
# AWS #
#######

# Print the autoscaling group in json format
get_asg() {
  local asg
  asg=$(aws --profile="${AWS_PROFILE}" autoscaling describe-auto-scaling-groups --auto-scaling-group-names="${ASG_NAME}" | jq '.AutoScalingGroups[0]')
  asg=$(parse_asg "${asg}")
  echo "${asg}"
}

parse_asg() {
  local asg=$1
  asg=$(echo "${asg}" | jq '{
    AutoScalingGroupName,
    DesiredCapacity,
    Instances,
    MaxSize,
    MinSize,
    SuspendedProcesses
  }')
  asg=$(echo "${asg}" | jq '.Instances |= map({InstanceId,AvailabilityZone}) ')
  echo "${asg}"
}

asg_status() {
  local timestamp=$1
  echo "ASG(mix/max/desired, disabled actions): $(asg_min_size "${timestamp}")/$(asg_max_size "${timestamp}")/$(asg_desired_size "${timestamp}"), TODO"
}

asg_min_size() {
  local timestamp=$1
  get_snapshot "${timestamp}" | jq -r '.asg.MinSize'
}

asg_max_size() {
  local timestamp=$1
  get_snapshot "${timestamp}" | jq -r '.asg.MaxSize'
}

asg_desired_size() {
  local timestamp=$1
  get_snapshot "${timestamp}" | jq -r '.asg.DesiredCapacity'
}

az_instance_status() {
  local timestamp=$1
  local instances total_count a_count b_count c_count
  instances=$(get_snapshot "${timestamp}" | jq '.asg.Instances')
  total_count=$(echo "${instances}" | jq 'length')
  a_count=$(echo "${instances}" | jq '[.[] | select(.AvailabilityZone == "eu-west-1a")] | length')
  b_count=$(echo "${instances}" | jq '[.[] | select(.AvailabilityZone == "eu-west-1b")] | length')
  c_count=$(echo "${instances}" | jq '[.[] | select(.AvailabilityZone == "eu-west-1c")] | length')
  echo "AWS Instances: ${total_count} (${a_count}/${b_count}/${c_count})"
}

########
# KUBE #
########

# Parses raw nodes to filter the information we don't need
# We keep name, AZ and creation date
parse_nodes() {
  local nodes=$1
  nodes=$(echo "${nodes}" | jq '[.items[] | {name: .metadata.name, zone: .metadata.labels."topology.kubernetes.io/zone", createdAt: .metadata.creationTimestamp} ] | sort_by(.createdAt |= fromdate) | reverse')
  echo "${nodes}"
}

# Prints the list of nodes in json format starting from the most recent
get_nodes() {
  local nodes
  nodes=$(retry kubectl --context "${KUBE_CONTEXT}" get node -l "role=${NODE_ROLE}" -o json)
  nodes=$(parse_nodes "${nodes}")
  echo "${nodes}"
}

az_node_status() {
  local timestamp=$1
  local nodes total_count a_count b_count c_count
  nodes=$(get_snapshot "${timestamp}" | jq '.nodes')
  total_count=$(echo "${nodes}" | jq 'length')
  a_count=$(echo "${nodes}" | jq '[.[] | select(.zone == "eu-west-1a")] | length')
  b_count=$(echo "${nodes}" | jq '[.[] | select(.zone == "eu-west-1b")] | length')
  c_count=$(echo "${nodes}" | jq '[.[] | select(.zone == "eu-west-1c")] | length')
  echo "Kube Nodes: ${total_count} (${a_count}/${b_count}/${c_count})"
}

##########
# REPORT #
##########

run_report() {
  make_snapshot
  full_report "${RUN_TIMESTAMP}" "now"
}

full_report() {
  local before=$1
  local after=$2

  echo "------------------------------------------------------------"
  echo "Full report:"
  echo ""
  cluster_report "${before}"
  echo ""
  changes_report "${before}" "${after}"
  echo ""
  cluster_report "${after}"
  echo "------------------------------------------------------------"
}

cluster_report() {
  local timestamp=$1

  echo "Cluster status at \"${timestamp}\":"
  echo "*  $(asg_status "${timestamp}")"
  echo "*  $(az_instance_status "${timestamp}")"
  echo "*  $(az_node_status "${timestamp}")"
}

# Returns the list of changes between two timestamps
changes() {
  local before=$1
  local after=$2

  data='{"before":'"$(get_snapshot "${before}")"',"after":'$(get_snapshot "${after}")'}'
  nodes=$(echo "${data}" | jq --compact-output '
    ( .after.nodes - .before.nodes | .[].change = "added" )
    +
    ( .before.nodes - .after.nodes | .[].change = "removed" )
  ')
  instances=$(echo "${data}" | jq --compact-output '
    ( .after.asg.Instances - .before.asg.Instances | .[].change = "added" )
    +
    ( .before.asg.Instances - .after.asg.Instances | .[].change = "removed" )
  ')
  echo '{"nodes":'"${nodes}"',"instances":'"${instances}"'}'
}

changes_report() {
  local before=$1
  local after=$2

  changes=$(changes "${before}" "${after}")
  nodes_added_total=$(echo "${changes}" | jq '[ .nodes[] | select(.change == "added") ] | length')
  nodes_added_a=$(echo "${changes}" | jq '[ .nodes[] | select(.change == "added") | select(.zone == "eu-west-1a") ] | length')
  nodes_added_b=$(echo "${changes}" | jq '[ .nodes[] | select(.change == "added") | select(.zone == "eu-west-1b") ] | length')
  nodes_added_c=$(echo "${changes}" | jq '[ .nodes[] | select(.change == "added") | select(.zone == "eu-west-1c") ] | length')
  nodes_removed_total=$(echo "${changes}" | jq '[ .nodes[] | select(.change == "removed") ] | length')
  nodes_removed_a=$(echo "${changes}" | jq '[ .nodes[] | select(.change == "removed") | select(.zone == "eu-west-1a") ] | length')
  nodes_removed_b=$(echo "${changes}" | jq '[ .nodes[] | select(.change == "removed") | select(.zone == "eu-west-1b") ] | length')
  nodes_removed_c=$(echo "${changes}" | jq '[ .nodes[] | select(.change == "removed") | select(.zone == "eu-west-1c") ] | length')
  instances_added_total=$(echo "${changes}" | jq '[ .instances[] | select(.change == "added") ] | length')
  instances_added_a=$(echo "${changes}" | jq '[ .instances[] | select(.change == "added") | select(.AvailabilityZone == "eu-west-1a") ] | length')
  instances_added_b=$(echo "${changes}" | jq '[ .instances[] | select(.change == "added") | select(.AvailabilityZone == "eu-west-1b") ] | length')
  instances_added_c=$(echo "${changes}" | jq '[ .instances[] | select(.change == "added") | select(.AvailabilityZone == "eu-west-1c") ] | length')
  instances_removed_total=$(echo "${changes}" | jq '[ .instances[] | select(.change == "removed") ] | length')
  instances_removed_a=$(echo "${changes}" | jq '[ .instances[] | select(.change == "removed") | select(.AvailabilityZone == "eu-west-1a") ] | length')
  instances_removed_b=$(echo "${changes}" | jq '[ .instances[] | select(.change == "removed") | select(.AvailabilityZone == "eu-west-1b") ] | length')
  instances_removed_c=$(echo "${changes}" | jq '[ .instances[] | select(.change == "removed") | select(.AvailabilityZone == "eu-west-1c") ] | length')

  instances_total="$(("${instances_added_total}" - "${instances_removed_total}")) ($(("${instances_added_a}" - "${instances_removed_a}"))/$(("${instances_added_b}" - "${instances_removed_b}"))/$(("${instances_added_c}" - "${instances_removed_c}")))"
  instances_added="${instances_added_total} (${instances_added_a}/${instances_added_b}/${instances_added_c})"
  instances_removed="${instances_removed_total} (${instances_removed_a}/${instances_removed_b}/${instances_removed_c})"
  nodes_total="$(("${nodes_added_total}" - "${nodes_removed_total}")) ($(("${nodes_added_a}" - "${nodes_removed_a}"))/$(("${nodes_added_b}" - "${nodes_removed_b}"))/$(("${nodes_added_c}" - "${nodes_removed_c}")))"
  nodes_added="${nodes_added_total} (${nodes_added_a}/${nodes_added_b}/${nodes_added_c})"
  nodes_removed="${nodes_removed_total} (${nodes_removed_a}/${nodes_removed_b}/${nodes_removed_c})"

  echo "Changes between \"${before}\" and \"${after}\":"
  echo "* Instances: +${instances_added} -${instances_removed} = ${instances_total}"
  echo "* Nodes: +${nodes_added} -${nodes_removed} = ${nodes_total}"
}

#############
# SNAPSHOTS #
#############

# Output the snapshot of the provided timestamp
get_snapshot() {
  local timestamp=$1
  jq --compact-output '.[] | select(.timestamp == "'"${timestamp}"'")' "${SNAPSHOTS_FILE}"
}

# Make a new snapshot and output its timestamp
make_snapshot() {
  local asg nodes now snapshots timestamp timestamped

  timestamp=$(timestamp_now)
  asg=$(get_asg | jq --compact-output)
  nodes=$(get_nodes | jq --compact-output)
  timestamped='{"timestamp": "'"${timestamp}"'","asg":'"${asg}"',"nodes":'"${nodes}"'}'
  now='{"timestamp": "now","asg":'"${asg}"',"nodes":'"${nodes}"'}'
  snapshots=$(jq --compact-output '.' "${SNAPSHOTS_FILE}")

  # Remove previous "now" snapshot
  snapshots=$(echo "${snapshots}" | jq '[ .[] | select(.timestamp != "now") ]')

  echo "${snapshots}" | jq --compact-output '. + ['"${timestamped}"'] + ['"${now}"']' >"${SNAPSHOTS_FILE}"
  echo "${timestamp}"
}

##############
# STATEMENTS #
##############

initialize
