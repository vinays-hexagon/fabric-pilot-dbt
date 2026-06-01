{#
  Overrides Elementary's default__get_package_database_and_schema.
  When ELEMENTARY_DISABLED=true, returns [none, none] which causes
  elementary.is_elementary_enabled() to return false, suppressing all
  on-run-start/end hooks. Used in CI to avoid T-SQL compatibility issues
  in Elementary's hook SQL (reserved keyword 'order').
#}
{% macro default__get_package_database_and_schema(package_name="elementary") %}
    {% if env_var('ELEMENTARY_DISABLED', 'false') == 'true' %}
        {{ return([none, none]) }}
    {% endif %}
    {% if execute %}
        {% set node_in_package = (
            graph.nodes.values()
            | selectattr("resource_type", "==", "model")
            | selectattr("package_name", "==", package_name)
            | first
        ) %}
        {% if node_in_package %}
            {{ return([node_in_package.database, node_in_package.schema]) }}
        {% endif %}
    {% endif %}
    {{ return([none, none]) }}
{% endmacro %}
