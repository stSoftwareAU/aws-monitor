#!/usr/bin/env bash
# Details <<<KEEP THESE UP TO DATE>>>
# Script: rollingDeploy.sh
# Function: Safely enforces an auto scaling group's launch configuration
# Input: the auto scaling group's name

set -o errexit
set -o pipefail
set -o nounset
#set -o xtrace # Uncomment to debug

# Parameters
declare -i tolerance=60*20              # minutes
declare -i scale_in_rest_period=60*3    # minutes
declare -i scale_out_rest_period=60*3   # minutes
declare -i monitoring_rest_period=30    # seconds
declare -i grace_period=60              # seconds

# Global declared variables
declare -i t0=$(date +%s)               #start the clock
declare -i time=$(($(date +%s) - t0))
declare -r auto_scaling_group_name="$1"

main() {
        # Variables 
        auto_scaling_group_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${auto_scaling_group_name}")
        if [ $(jq -r '.AutoScalingGroups | length'<<<"${auto_scaling_group_json}") != 1 ]; then
                 &>2 echo "There is not one unique auto scaling group by the name of ${auto_scaling_group_name}"
                 exit 1
        fi
        launch_configuration_name=$(jq -r '.AutoScalingGroups[].LaunchConfigurationName'<<<"${auto_scaling_group_json}")
        min_size=$(jq -r '.AutoScalingGroups[].MinSize'<<<"${auto_scaling_group_json}")
        max_size=$(jq -r '.AutoScalingGroups[].MaxSize'<<<"${auto_scaling_group_json}")
        if [ $min_size -eq $max_size ]; then
                &>2 echo "${auto_scaling_group_name} is configured with min-size = max-size"
                exit 1
        fi

        # Rolling deploy 
        if satisfied; then
                echo "auto scaling group ${auto_scaling_group_name} already compliant"
                exit 0
        else
                # Set termination policies 
                aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --termination-policies "OldestInstance" "Default"

                while ! satisfied && [ $time -lt $tolerance ]; do
                        # set min to the current number of healty machines + number of new machines needed, if it does not exceed the maximum.
                        count_number_of_new_machines_needed
                        number_healthy=$(jq '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService")] | length' \
                                <<<"${auto_scaling_group_json}")
                        declare -i new_min=$((number_healthy + number_of_new_machines_needed < max_size ? number_healthy + number_of_new_machines_needed: max_size))
                        aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --min-size $new_min

                        sleep $scale_in_rest_period
                        time=$(($(date +%s) - t0))
                        monitor_until_stable
                        sleep $grace_period

                        aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --min-size $min_size --desired-capacity $min_size

                        sleep $scale_out_rest_period
                        time=$(($(date +%s) - t0))
                        monitor_until_stable

                        # Update variables
                        auto_scaling_group_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${auto_scaling_group_name}")
                        launch_configuration_name=$(jq -r '.AutoScalingGroups[].LaunchConfigurationName'<<<"${auto_scaling_group_json}")
                        time=$(($(date +%s) - t0))
                done
        fi

        # Reset launch config, min, max, and desired.
        aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" \
                --min-size $min_size --desired-capacity $min_size \
                --termination-policies "OldestLaunchConfiguration" "OldestInstance" "Default"

        # Confirm successful deploy
        if ! satisfied; then
                &>2 echo "Rolling deploy failed for ${auto_scaling_group_name}"
                exit 1
        fi
}

# checks the launch configuration is satisfied
satisfied() {
        count_healthy_instances
        if [[ "${launch_configuration_name}" =~ .*#costly[^a-z,0-9].* ]]; then
                local number_healthy_and_correct=$(jq --arg lcn1 "${launch_configuration_name}" --arg lcn2 "${launch_configuration_name//\#costly/\#spot}" \
                        '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService" and
                        (.LaunchConfigurationName==$lcn1 or .LaunchConfigurationName==$lcn2))] | length' <<< "${auto_scaling_group_json}")
        else
                local number_healthy_and_correct=$(jq --arg lcn "${launch_configuration_name}" \
                        '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService" and .LaunchConfigurationName==$lcn)] | length' \
                        <<< "${auto_scaling_group_json}")
        fi
        if [ "${number_healthy}" -ge "${min_size}" ] && [ "${number_healthy}" -eq "${number_healthy_and_correct}" ]; then
                true; return
        else
                false; return
        fi
}

# checks the system is stable
stable() {
        auto_scaling_group_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${auto_scaling_group_name}")
        count_healthy_instances
        local number_instances=$(jq '[.AutoScalingGroups[].Instances[] | select(.LifecycleState!="Terminating")] | length'<<<"${auto_scaling_group_json}")
        local desired_capacity=$(jq -r '.AutoScalingGroups[].DesiredCapacity'<<<"${auto_scaling_group_json}")

        if [ ${number_instances} -eq ${number_healthy} ] && [ $number_healthy -eq $desired_capacity ]; then
                true; return
        else
                false; return
        fi
}

monitor_until_stable() {
        while  ! stable  && [ $time -lt $tolerance ]; do
                sleep $monitoring_rest_period
                time=$(($(date +%s) - t0))
        done
}

# set number_healthy by counting the number of healthy instances in the autoscaling group.
count_healthy_instances() {
        local health_check_type=$(jq -r '.AutoScalingGroups[].HealthCheckType'<<<"${auto_scaling_group_json}")

        if [ $health_check_type = "EC2" ]; then
                number_healthy=$(jq '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService")] | length' \
                        <<<"${auto_scaling_group_json}")
        elif [ $health_check_type = "ELB" ]; then
                local target_groups_json=`aws autoscaling describe-load-balancer-target-groups --auto-scaling-group-name "${auto_scaling_group_name}"`
                local target_groups=$(jq -r '.LoadBalancerTargetGroups[] | .LoadBalancerTargetGroupARN'<<<"${target_groups_json}")
                local instances=$(jq -r --raw-output '.AutoScalingGroups[].Instances[].InstanceId'<<<"${auto_scaling_group_json}")
                number_healthy=0
                declare -i healthy_bool=0

                for instance in $instances; do
                        for target_group_arn in "$target_groups"; do
                                local targets_json=$(aws elbv2 describe-target-health --target-group-arn "${target_group_arn}")
                                healthy_bool=$(jq --arg id "$instance"\
                                         '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy" and .Target.Id == $id)] | length'\
                                        <<< "${targets_json}")
                                [ $healthy_bool -eq 0 ] && break || healthy_bool=1
                        done
                        number_healthy=$((number_healthy + healthy_bool))
                done
        else
                &>2 echo "${auto_scaling_group_name} has unhandled health check type"

                aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" \
                        --min-size $min_size --max-size $max_size --desired-capacity $min_size \
                        --termination-policies "OldestLaunchConfiguration" "OldestInstance" "Default"

                exit 1
        fi
}

count_number_of_new_machines_needed() {
        if [[ "${launch_configuration_name}" =~ .*#costly[^a-z,0-9].* ]]; then
                local number_healthy_and_correct=$(jq --arg lcn1 "${launch_configuration_name}" --arg lcn2 "${launch_configuration_name//\#costly/\#spot}" \
                        '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService" and
                        (.LaunchConfigurationName==$lcn1 or .LaunchConfigurationName==$lcn2))] | length' <<< "${auto_scaling_group_json}")
        else
                local number_healthy_and_correct=$(jq --arg lcn "${launch_configuration_name}" \
                        '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService" and .LaunchConfigurationName==$lcn)] | length' \
                        <<< "${auto_scaling_group_json}")
        fi

        number_of_new_machines_needed=$((min_size - number_healthy_and_correct))
        if [ $number_of_new_machines_needed -lt 0 ]; then
                 number_of_new_machines_needed=0
        fi
}

main "$@"
