# encoding: utf-8
require "spec_helper"
require_relative "../support/helpers"
require "logstash/state_resolver"
require "logstash/config/config_part"
require "logstash/config/pipeline_config"
require "logstash/instrument/null_metric"
require "logstash/pipeline"
require "ostruct"
require "digest"


def mock_pipeline(pipeline_id, reloadable = true, config_hash = nil)
  config_string = "input { stdin { id => '#{pipeline_id}' }}"
  settings = mock_settings("pipeline.id" => pipeline_id.to_s, "config.string" => config_string)
  pipeline = LogStash::Pipeline.new(config_string, settings)
  allow(pipeline).to receive(:reloadable?).and_return(true) if !reloadable
  pipeline
end

def mock_pipeline_config(pipeline_id, config_string = nil)
  config_string = "input { stdin { id => '#{pipeline_id}' }}" if config_string.nil?
  config_part = LogStash::Config::ConfigPart.new(:config_string, "config_string", config_string)
  LogStash::Config::PipelineConfig.new(LogStash::Config::Source::Local, pipeline_id, config_part, mock_settings({}))
end

RSpec::Matchers.define :have_actions do |*expected|
  match do |actual|
    expect(actual.size).to eq(expected.size)

    expected_values = expected.each_with_object([]) do |i, obj|
      klass_name = "LogStash::PipelineAction::#{i.first.capitalize}"
      obj << [klass_name, i.last]
    end

    actual_values = actual.each_with_object([]) do |i, obj|
      klass_name = i.class.name
      obj << [klass_name, i.pipeline_id]
    end

    values_match? expected_values, actual_values
  end
end

describe LogStash::StateResolver do
  subject { described_class.new(metric) }
  let(:metric) { LogStash::Instrument::NullMetric.new }

  context "when no pipeline is running" do
    let(:running_pipelines) { {} }

    context "no pipeline configs is received" do
      let(:pipeline_configs) { [] }

      it "returns no action" do
        expect(subject.resolve(running_pipelines, pipeline_configs).size).to eq(0)
      end
    end

    context "we receive some pipeline configs" do
      let(:pipeline_configs) { [mock_pipeline_config(:hello_world)] }

      it "returns some actions" do
        expect(subject.resolve(running_pipelines, pipeline_configs)).to have_actions(
          [:create, :hello_world],
        )
      end
    end
  end

  context "when some pipeline are running" do
    context "when a pipeline is running" do
      let(:running_pipelines) { { :main => mock_pipeline(:main) } }

      context "when the pipeline config contains a new one and the existing" do
        let(:pipeline_configs) { [mock_pipeline_config(:hello_world), mock_pipeline_config(:main)] }

        it "creates the new one and keep the other one" do
          expect(subject.resolve(running_pipelines, pipeline_configs)).to have_actions(
            [:create, :hello_world],
          )
        end

        context "when the pipeline config contains only the new one" do
          let(:pipeline_configs) { [mock_pipeline_config(:hello_world)] }

          it "creates the new one and stop the old one one" do
            expect(subject.resolve(running_pipelines, pipeline_configs)).to have_actions(
              [:create, :hello_world],
              [:stop, :main]
            )
          end
        end

        context "when the pipeline config contains no pipeline" do
          let(:pipeline_configs) { [] }

          it "stops the old one one" do
            expect(subject.resolve(running_pipelines, pipeline_configs)).to have_actions(
              [:stop, :main]
            )
          end
        end

        context "when pipeline config contains an updated pipeline" do
          let(:pipeline_configs) { [mock_pipeline_config(:main, "input { generator {}}")] }

          it "reloads the old one one" do
            expect(subject.resolve(running_pipelines, pipeline_configs)).to have_actions(
              [:reload, :main]
            )
          end
        end
      end
    end

    context "when we have a lot of pipeline running" do
      let(:running_pipelines) do
        {
          :main1 => mock_pipeline(:main1),
          :main2 => mock_pipeline(:main2),
          :main3 => mock_pipeline(:main3),
          :main4 => mock_pipeline(:main4),
          :main5 => mock_pipeline(:main5),
          :main6 => mock_pipeline(:main6),
        }
      end

      let(:pipeline_configs) do
        [
          mock_pipeline_config(:main1),
          mock_pipeline_config(:main9),
          mock_pipeline_config(:main5, "input { generator {}}"),
          mock_pipeline_config(:main3, "input { generator {}}"),
          mock_pipeline_config(:main7)
        ]
      end

      it "generates actions required to converge" do
        expect(subject.resolve(running_pipelines, pipeline_configs)).to have_actions(
          [:create, :main7],
          [:create, :main9],
          [:reload, :main3],
          [:reload, :main5],
          [:stop, :main2],
          [:stop, :main4],
          [:stop, :main6]
        )
      end
    end
  end
end