child :content_facet => :content_facet_attributes do
  extends 'katello/api/v2/content_facet/base'

  node do |content_facet|
    version = content_facet.content_view_version
    {
      :content_view_version => version.version,
      :content_view_version_id => version.id,
      :content_view_version_latest => version.latest?
    }
  end

  node :content_view_default? do |content_facet|
    content_facet.content_view.default?
  end

  node :lifecycle_environment_library? do |content_facet|
    content_facet.lifecycle_environment.library?
  end

  node :katello_agent_installed do |content_facet|
    content_facet.katello_agent_installed?
  end

  node :katello_tracer_installed do |content_facet|
    content_facet.tracer_installed?
  end
end

attributes :description, :facts
