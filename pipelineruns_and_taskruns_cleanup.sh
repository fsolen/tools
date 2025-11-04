for ns in $(oc get ns -o jsonpath='{.items[*].metadata.name}'); do
  echo "Cleaning namespace: $ns"

  # === PIPELINERUNS ===
  for pr in $(oc get pipelineruns -n $ns -o jsonpath='{range .items[?(@.status.conditions[0].reason=="Succeeded")]}{.metadata.name}{"\n"}{end}'; \
               oc get pipelineruns -n $ns -o jsonpath='{range .items[?(@.status.conditions[0].reason=="Failed")]}{.metadata.name}{"\n"}{end}'); do
    echo "Patching & deleting PipelineRun: $pr"
    oc patch pipelinerun "$pr" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge
    oc delete pipelinerun "$pr" -n "$ns" --ignore-not-found
  done

  # === TASKRUNS ===
  for tr in $(oc get taskruns -n $ns -o jsonpath='{range .items[?(@.status.conditions[0].reason=="Succeeded")]}{.metadata.name}{"\n"}{end}'; \
               oc get taskruns -n $ns -o jsonpath='{range .items[?(@.status.conditions[0].reason=="Failed")]}{.metadata.name}{"\n"}{end}'); do
    echo "Patching & deleting TaskRun: $tr"
    oc patch taskrun "$tr" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge
    oc delete taskrun "$tr" -n "$ns" --ignore-not-found
  done

done
