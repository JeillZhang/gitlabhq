# frozen_string_literal: true
require 'spec_helper'

RSpec.describe 'container repository details', feature_category: :container_registry do
  include_context 'container registry tags'
  include_context 'container registry client stubs'

  using RSpec::Parameterized::TableSyntax
  include GraphqlHelpers

  let_it_be_with_reload(:project) { create(:project) }
  let_it_be_with_reload(:container_repository) { create(:container_repository, project: project) }

  let(:excluded) { %w[pipeline size agentConfigurations iterations iterationCadences productAnalyticsState] }
  let(:query) do
    graphql_query_for(
      'containerRepository',
      { id: container_repository_global_id },
      all_graphql_fields_for('ContainerRepositoryDetails', excluded: excluded, max_depth: 4)
    )
  end

  let(:user) { project.first_owner }
  let(:variables) { {} }
  let(:tags) { %w[latest tag1 tag2 tag3 tag4 tag5] }
  let(:container_repository_global_id) { container_repository.to_global_id.to_s }
  let(:container_repository_details_response) { graphql_data.dig('containerRepository') }

  before do
    stub_container_registry_config(enabled: true)
    stub_container_registry_tags(repository: container_repository.path, tags: tags, with_manifest: true)
  end

  subject { post_graphql(query, current_user: user, variables: variables) }

  shared_examples 'returning an invalid value error' do
    it 'returns an error' do
      subject

      expect(graphql_errors.first.dig('message')).to match(/invalid value/)
    end
  end

  it_behaves_like 'a working graphql query' do
    before do
      subject
    end

    it 'matches the JSON schema' do
      expect(container_repository_details_response).to match_schema('graphql/container_repository_details')
    end
  end

  context 'with different permissions' do
    let_it_be(:user) { create(:user) }

    let(:tags_response) { container_repository_details_response.dig('tags', 'nodes') }

    where(:project_visibility, :role, :access_granted, :can_delete) do
      :private | :maintainer | true  | true
      :private | :developer  | true  | true
      :private | :reporter   | true  | false
      :private | :guest      | false | false
      :private | :anonymous  | false | false
      :public  | :maintainer | true  | true
      :public  | :developer  | true  | true
      :public  | :reporter   | true  | false
      :public  | :guest      | true  | false
      :public  | :anonymous  | true  | false
    end

    with_them do
      before do
        project.update!(visibility_level: Gitlab::VisibilityLevel.const_get(project_visibility.to_s.upcase, false))
        project.add_member(user, role) unless role == :anonymous
      end

      it 'return the proper response' do
        subject

        if access_granted
          expect(tags_response.size).to eq(tags.size)
          expect(container_repository_details_response.dig('canDelete')).to eq(can_delete)
        else
          expect(container_repository_details_response).to eq(nil)
        end
      end
    end
  end

  context 'with a giant size tag' do
    let(:tags) { %w[latest] }
    let(:giant_size) { 1.terabyte }
    let(:tag_sizes_response) { graphql_data_at('containerRepository', 'tags', 'nodes', 'totalSize') }
    let(:fields) do
      <<~GQL
        tags {
          nodes {
            totalSize
          }
        }
      GQL
    end

    let(:query) do
      graphql_query_for(
        'containerRepository',
        { id: container_repository_global_id },
        fields
      )
    end

    it 'returns the expected value as a string' do
      stub_next_container_registry_tags_call(:total_size, giant_size)

      subject

      expect(tag_sizes_response.first).to eq(giant_size.to_s)
    end
  end

  context 'limiting the number of tags' do
    let(:limit) { 2 }
    let(:tags_response) { container_repository_details_response.dig('tags', 'edges') }
    let(:variables) do
      { id: container_repository_global_id, n: limit }
    end

    let(:query) do
      <<~GQL
        query($id: ContainerRepositoryID!, $n: Int) {
          containerRepository(id: $id) {
            tags(first: $n) {
              edges {
                node {
                  #{all_graphql_fields_for('ContainerRepositoryTag')}
                }
              }
            }
          }
        }
      GQL
    end

    it 'only returns n tags' do
      subject

      expect(tags_response.size).to eq(limit)
    end
  end

  context 'sorting the tags' do
    let(:sort) { 'NAME_DESC' }
    let(:tags_response) { container_repository_details_response.dig('tags', 'edges') }
    let(:variables) do
      { id: container_repository_global_id, n: sort }
    end

    let(:query) do
      <<~GQL
        query($id: ContainerRepositoryID!, $n: ContainerRepositoryTagSort) {
          containerRepository(id: $id) {
            tags(sort: $n) {
              edges {
                node {
                  #{all_graphql_fields_for('ContainerRepositoryTag')}
                }
              }
            }
          }
        }
      GQL
    end

    it 'sorts the tags', :aggregate_failures do
      subject

      expect(tags_response.first.dig('node', 'name')).to eq('tag5')
      expect(tags_response.last.dig('node', 'name')).to eq('latest')
    end

    context 'invalid sort' do
      let(:sort) { 'FOO_ASC' }

      it_behaves_like 'returning an invalid value error'
    end
  end

  context 'filtering by name' do
    let(:name) { 'l' }
    let(:tags_response) { container_repository_details_response.dig('tags', 'edges') }
    let(:variables) do
      { id: container_repository_global_id, n: name }
    end

    let(:query) do
      <<~GQL
        query($id: ContainerRepositoryID!, $n: String) {
          containerRepository(id: $id) {
            tags(name: $n) {
              edges {
                node {
                  #{all_graphql_fields_for('ContainerRepositoryTag')}
                }
              }
            }
          }
        }
      GQL
    end

    it 'sorts the tags', :aggregate_failures do
      subject

      expect(tags_response.size).to eq(1)
      expect(tags_response.first.dig('node', 'name')).to eq('latest')
    end

    context 'invalid filter' do
      let(:name) { 1 }

      it_behaves_like 'returning an invalid value error'
    end
  end

  context 'size field' do
    let(:size_response) { container_repository_details_response.dig('size') }
    let(:variables) do
      { id: container_repository_global_id }
    end

    let(:query) do
      <<~GQL
        query($id: ContainerRepositoryID!) {
          containerRepository(id: $id) {
            size
          }
        }
      GQL
    end

    it 'returns the size' do
      stub_container_registry_gitlab_api_support(supported: true) do |client|
        stub_container_registry_gitlab_api_repository_details(client, path: container_repository.path, size_bytes: 12345)
      end

      subject

      expect(size_response).to eq(12345)
    end

    context 'with a network error' do
      it 'returns an error' do
        stub_container_registry_gitlab_api_network_error

        subject

        expect_graphql_errors_to_include("Can't connect to the Container Registry. If this error persists, please review the troubleshooting documentation.")
      end
    end

    context 'with not supporting the gitlab api' do
      it 'returns nil' do
        stub_container_registry_gitlab_api_support(supported: false)

        subject

        expect(size_response).to eq(nil)
      end
    end
  end

  context 'with tags with a manifest containing nil fields' do
    let(:tags_response) { container_repository_details_response.dig('tags', 'nodes') }
    let(:errors) { container_repository_details_response.dig('errors') }

    %i[digest revision short_revision total_size created_at].each do |nilable_field|
      it "returns a list of tags with a nil #{nilable_field}" do
        stub_next_container_registry_tags_call(nilable_field, nil)

        subject

        expect(tags_response.size).to eq(tags.size)
        expect(graphql_errors).to eq(nil)
      end
    end
  end

  it_behaves_like 'handling graphql network errors with the container registry'

  context 'when list tags API is enabled', :saas do
    before do
      stub_container_registry_config(enabled: true)
      allow(ContainerRegistry::GitlabApiClient).to receive(:supports_gitlab_api?).and_return(true)

      allow_next_instances_of(ContainerRegistry::GitlabApiClient, nil) do |client|
        allow(client).to receive(:tags).and_return(response_body)
      end
    end

    let_it_be(:raw_tags_response) do
      [
        {
          name: 'latest',
          digest: 'sha256:1234567892',
          config_digest: 'sha256:3332132331',
          media_type: 'application/vnd.oci.image.manifest.v1+json',
          size_bytes: 1234567892,
          created_at: 10.minutes.ago,
          updated_at: 10.minutes.ago
        }
      ]
    end

    let_it_be(:url) { URI('/gitlab/v1/repositories/group1/proj1/tags/list/?before=tag1') }

    let_it_be(:response_body) do
      {
        pagination: { previous: { uri: url }, next: { uri: url } },
        response_body: ::Gitlab::Json.parse(raw_tags_response.to_json)
      }
    end

    it_behaves_like 'a working graphql query' do # OK
      before do
        subject
      end

      it 'matches the JSON schema' do
        expect(container_repository_details_response).to match_schema('graphql/container_repository_details')
      end
    end

    context 'with different permissions' do # OK
      let_it_be(:user) { create(:user) }

      let(:tags_response) { container_repository_details_response.dig('tags', 'nodes') }

      where(:project_visibility, :role, :access_granted, :can_delete) do
        :private | :maintainer | true  | true
        :private | :developer  | true  | true
        :private | :reporter   | true  | false
        :private | :guest      | false | false
        :private | :anonymous  | false | false
        :public  | :maintainer | true  | true
        :public  | :developer  | true  | true
        :public  | :reporter   | true  | false
        :public  | :guest      | true  | false
        :public  | :anonymous  | true  | false
      end

      with_them do
        before do
          project.update!(visibility_level: Gitlab::VisibilityLevel.const_get(project_visibility.to_s.upcase, false))
          project.add_member(user, role) unless role == :anonymous
        end

        it 'return the proper response' do
          subject

          if access_granted
            expect(tags_response.size).to eq(raw_tags_response.size)
            expect(container_repository_details_response.dig('canDelete')).to eq(can_delete)
          else
            expect(container_repository_details_response).to eq(nil)
          end
        end
      end
    end

    context 'querying' do
      let(:name) { 'l' }
      let(:tags_response) { container_repository_details_response.dig('tags', 'edges') }
      let(:variables) do
        { id: container_repository_global_id, n: name }
      end

      let(:query) do
        <<~GQL
          query($id: ContainerRepositoryID!, $n: String) {
            containerRepository(id: $id) {
              tags(name: $n) {
                edges {
                  node {
                    #{all_graphql_fields_for('ContainerRepositoryTag')}
                  }
                }
              }
            }
          }
        GQL
      end

      it 'returns the tag response', :aggregate_failures do
        subject

        expect(tags_response.size).to eq(1)
        expect(tags_response.first.dig('node', 'name')).to eq('latest')
      end

      context 'invalid filter' do
        let(:name) { 1 }

        it_behaves_like 'returning an invalid value error'
      end

      context 'with referrers' do
        let(:tags_response) { container_repository_details_response.dig('tags', 'edges') }
        let(:raw_tags_response) do
          [
            {
              name: 'latest',
              digest: 'sha256:1234567892',
              config_digest: 'sha256:3332132331',
              media_type: 'application/vnd.oci.image.manifest.v1+json',
              size_bytes: 1234509876,
              created_at: 10.minutes.ago,
              updated_at: 10.minutes.ago,
              referrers: [
                {
                  artifactType: 'application/vnd.example+type',
                  digest: 'sha256:57d3be92c2f857566ecc7f9306a80021c0a7fa631e0ef5146957235aea859961'
                },
                {
                  artifactType: 'application/vnd.example+type+2',
                  digest: 'sha256:01db72e42d61b8d2183d53475814cce2bfb9c8a254e97539a852441979cd5c90'
                }
              ]
            },
            {
              name: 'latest',
              digest: 'sha256:1234567893',
              config_digest: 'sha256:3332132331',
              media_type: 'application/vnd.oci.image.manifest.v1+json',
              size_bytes: 1234509877,
              created_at: 9.minutes.ago,
              updated_at: 9.minutes.ago
            }
          ]
        end

        let(:query) do
          <<~GQL
            query($id: ContainerRepositoryID!, $n: String) {
              containerRepository(id: $id) {
                tags(name: $n, referrers: true) {
                  edges {
                    node {
                      #{all_graphql_fields_for('ContainerRepositoryTag')}
                    }
                  }
                }
              }
            }
          GQL
        end

        let(:url) { URI('/gitlab/v1/repositories/group1/proj1/tags/list/?before=tag1&referrers=true') }

        let(:response_body) do
          {
            pagination: { previous: { uri: url }, next: { uri: url } },
            response_body: ::Gitlab::Json.parse(raw_tags_response.to_json)
          }
        end

        it 'includes referrers in response' do
          subject

          refs = tags_response.map { |tag| tag.dig('node', 'referrers') }

          expect(refs.first.size).to eq(2)
          expect(refs.first.first).to include({
            'artifactType' => 'application/vnd.example+type',
            'digest' => 'sha256:57d3be92c2f857566ecc7f9306a80021c0a7fa631e0ef5146957235aea859961'
          })
          expect(refs.first.second).to include({
            'artifactType' => 'application/vnd.example+type+2',
            'digest' => 'sha256:01db72e42d61b8d2183d53475814cce2bfb9c8a254e97539a852441979cd5c90'
          })

          expect(refs.second).to be_empty
        end
      end
    end

    it_behaves_like 'handling graphql network errors with the container registry'
  end
end
