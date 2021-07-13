#!/usr/bin/env bash

# Library to provide reporting functionality to the aws cluster roll
#
# Assumptions:
# * rolls happen for a single role at a time
# * each role is managed by a single autoscaling group (asg)
#
# Usage:
# * library should be sourced by `kube-aws-updater`
# * call `run_report` to get a report for the ongoin run
#
# Shell style guide: https://google.github.io/styleguide/shellguide.html

set -o errexit
set -o nounset
set -o pipefail

################
# GLOBAL STATE #
################

readonly KUBE_CONTEXT="${kube_context:?"Error: variable 'kube_context' must be set"}"
readonly NODE_ROLE="${role:?"Error: variable 'role' must be set"}"
readonly AWS_PROFILE="${aws_profile:?"Error: variable 'aws_profile' must be set"}"
readonly SNAPSHOTS_FILE="${SNAPSHOTS_FILE:-"./snapshots.json"}"

ASG_NAME=""
RUN_TIMESTAMP="" # ISO8601 UTC

###########
# SUPPORT #
###########

# Get the current timestamp, ISO8601 UTC format
timestamp_now() {
  date --utc +'%Y-%m-%dT%H:%M:%SZ'
}

# Initialize global state. Order is important
initialize() {
  if [ ! -s "${SNAPSHOTS_FILE}" ]; then
    echo "[]" >"${SNAPSHOTS_FILE}"
  fi

  ASG_NAME=$(get_asg_name)
  RUN_TIMESTAMP=$(make_snapshot) # ISO8601 UTC
}

get_global_state() {
  echo "KUBE_CONTEXT(ro): ${KUBE_CONTEXT}"
  echo "NODE_ROLE(ro): ${NODE_ROLE}"
  echo "AWS_PROFILE(ro): ${AWS_PROFILE}"
  echo "SNAPSHOTS_FILE(ro): ${SNAPSHOTS_FILE}"
  echo "ASG_NAME: ${ASG_NAME}"
  echo "RUN_TIMESTAMP:  ${RUN_TIMESTAMP}"
}

########
# ROLL #
########

# Get asg name that manages the rolling node's role
get_asg_name() {
  local addresses instances asg_name
  addresses=$(retry kubectl --context "${KUBE_CONTEXT}" get node -l "role=${NODE_ROLE}" -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}' | sed 's/.$//')
  instances=$(retry aws --profile "${AWS_PROFILE}" ec2 describe-instances --max-items=1 --filters "Name=network-interface.private-dns-name,Values=${addresses}")
  asg_name=$(echo "${instances}" | jq -r '.Reservations | first | .Instances | first | .Tags[] | select(.Key == "aws:autoscaling:groupName") | .Value')
  echo "${asg_name}"
}

############
# MACHINES #
############

# Takes an array of objects with "zone" and counts them
az_count() {
  local machines=$1

  local total_count a_count b_count c_count
  total_count=$(echo "${machines}" | jq 'length')
  a_count=$(echo "${machines}" | jq '[.[] | select(.zone == "eu-west-1a")] | length')
  b_count=$(echo "${machines}" | jq '[.[] | select(.zone == "eu-west-1b")] | length')
  c_count=$(echo "${machines}" | jq '[.[] | select(.zone == "eu-west-1c")] | length')
  echo "${total_count} (${a_count}/${b_count}/${c_count})"
}

# Substract two az counts of the format "3 (1/1/1)"
az_count_diff() {
  local added=$1
  local removed=$2

  local add add_az add_a add_b add_c rmv rmv_az rmv_a rmv_b rmv_c
  add=$(echo "${added}" | awk -F " " '{print $1}')
  add_az=$(echo "${added}" | awk -F " " '{print $2}' | tr -d "()")
  add_a=$(echo "${add_az}" | awk -F "/" '{print $1}')
  add_b=$(echo "${add_az}" | awk -F "/" '{print $2}')
  add_c=$(echo "${add_az}" | awk -F "/" '{print $3}')
  rmv=$(echo "${removed}" | awk -F " " '{print $1}')
  rmv_az=$(echo "${removed}" | awk -F " " '{print $2}' | tr -d "()")
  rmv_a=$(echo "${rmv_az}" | awk -F "/" '{print $1}')
  rmv_b=$(echo "${rmv_az}" | awk -F "/" '{print $2}')
  rmv_c=$(echo "${rmv_az}" | awk -F "/" '{print $3}')

  echo "$(("${add}" - "${rmv}")) ($(("${add_a}" - "${rmv_a}"))/$(("${add_b}" - "${rmv_b}"))/$(("${add_c}" - "${rmv_c}")))"
}

# Takes two arrays of objects with "id" and outputs objects that were added and substracted
machine_diff() {
  local before=$1
  local after=$2

  local before_ids after_ids data added removed
  before_ids=$(echo "${before}" | jq --compact-output 'map(.id)')
  after_ids=$(echo "${after}" | jq --compact-output 'map(.id)')
  data='{
    "before":{
      "ids":'"${before_ids}"',
      "data":'"${before}"'
    },
    "after":{
      "ids":'"${after_ids}"',
      "data":'"${after}"'
    }
  }'
  added=$(echo "${data}" | jq --compact-output '.
  | (.after.ids - .before.ids) as $ids
  | [ .after.data[] | select([.id] | inside ($ids)) ]
  ')
  removed=$(echo "${data}" | jq --compact-output '.
  | (.before.ids - .after.ids) as $ids
  | [ .before.data[] | select([.id] | inside ($ids)) ]
  ')

  echo '{"added":'"${added}"',"removed":'"${removed}"'}'
}

#######
# AWS #
#######

# Get the asg data from its name
get_asg() {
  local asg_name=$1

  local asg
  asg=$(retry aws --profile="${AWS_PROFILE}" autoscaling describe-auto-scaling-groups --auto-scaling-group-names="${asg_name}" | jq '.AutoScalingGroups[0]')
  asg=$(parse_asg "${asg}")
  echo "${asg}"
}

# Filters asg data to keep only what we need
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
  asg=$(echo "${asg}" | jq '.Instances |= map({id: .InstanceId, zone: .AvailabilityZone}) ')
  echo "${asg}"
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

asg_disabled_actions_count() {
  local timestamp=$1

  get_snapshot "${timestamp}" | jq -r '.asg.SuspendedProcesses | length'
}

asg_status() {
  local timestamp=$1

  echo "ASG(mix,max,desired,disabled actions): $(asg_min_size "${timestamp}"),$(asg_max_size "${timestamp}"),$(asg_desired_size "${timestamp}"),$(asg_disabled_actions_count "${timestamp}")"
}

az_instance_status() {
  local timestamp=$1

  local instances
  instances=$(get_snapshot "${timestamp}" | jq '.asg.Instances')
  echo "AWS Instances: $(az_count "${instances}")"
}

instance_diff() {
  local before=$1
  local after=$2

  before=$(get_snapshot "${before}" | jq '.asg.Instances')
  after=$(get_snapshot "${after}" | jq '.asg.Instances')
  machine_diff "${before}" "${after}"
}

########
# KUBE #
########

# Get nodes' data
get_nodes() {
  local nodes
  nodes=$(retry kubectl --context "${KUBE_CONTEXT}" get node -l "role=${NODE_ROLE}" -o json)
  nodes=$(parse_nodes "${nodes}")
  echo "${nodes}"
}

# Filters nodes data to keep only what we need
parse_nodes() {
  local nodes=$1

  nodes=$(echo "${nodes}" | jq '.items | map({ 
    id: (.metadata.name + "-" + .metadata.creationTimestamp),
    name: .metadata.name,
    zone: .metadata.labels."topology.kubernetes.io/zone",
    retiring: .metadata.labels.retiring
  })')
  echo "${nodes}"
}

az_node_status() {
  local timestamp=$1

  local nodes nodes_new nodes_old
  nodes=$(get_snapshot "${timestamp}" | jq '.nodes')
  nodes_old=$(echo "${nodes}" | jq '[.[] | select(.retiring != null)]')
  nodes_new=$(echo "${nodes}" | jq '[.[] | select(.retiring == null)]')
  echo "Kube Nodes (all, new, old): $(az_count "${nodes}"), $(az_count "${nodes_new}"), $(az_count "${nodes_old}")"
}

node_diff() {
  local before=$1
  local after=$2

  before=$(get_snapshot "${before}" | jq '.nodes')
  after=$(get_snapshot "${after}" | jq '.nodes')
  machine_diff "${before}" "${after}"
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
  echo "Full report of ${ASG_NAME}:"
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
  echo "* $(asg_status "${timestamp}")"
  echo "* $(az_instance_status "${timestamp}")"
  echo "* $(az_node_status "${timestamp}")"
}

changes_report() {
  local before=$1
  local after=$2

  local node_changes instance_changes nodes_added nodes_removed instances_added instances_removed
  node_changes=$(node_diff "${before}" "${after}")
  instance_changes=$(instance_diff "${before}" "${after}")
  nodes_added=$(echo "${node_changes}" | jq '.added')
  nodes_removed=$(echo "${node_changes}" | jq '.removed')
  instances_added=$(echo "${instance_changes}" | jq '.added')
  instances_removed=$(echo "${instance_changes}" | jq '.removed')

  local nodes_added_az_count nodes_removed_az_count nodes_total_az_count instances_added_az_count instances_removed_az_count instances_total_az_count
  nodes_added_az_count=$(az_count "${nodes_added}")
  nodes_removed_az_count=$(az_count "${nodes_removed}")
  nodes_total_az_count=$(az_count_diff "${nodes_added_az_count}" "${nodes_removed_az_count}")
  instances_added_az_count=$(az_count "${instances_added}")
  instances_removed_az_count=$(az_count "${instances_removed}")
  instances_total_az_count=$(az_count_diff "${instances_added_az_count}" "${instances_removed_az_count}")

  echo "Changes between \"${before}\" and \"${after}\":"
  echo "* AWS Instances: +${instances_added_az_count} -${instances_removed_az_count} = ${instances_total_az_count}"
  echo "* Kube Nodes: +${nodes_added_az_count} -${nodes_removed_az_count} = ${nodes_total_az_count}"
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
  local timestamp asg nodes timestamped now snapshots
  timestamp=$(timestamp_now)
  asg=$(get_asg "${ASG_NAME}" | jq --compact-output)
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
