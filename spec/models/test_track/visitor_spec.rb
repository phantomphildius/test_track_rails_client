require 'rails_helper'

RSpec.describe TestTrack::Visitor do
  let(:new_visitor) { described_class.new }
  let(:existing_visitor) { described_class.new(id: existing_visitor_id) }
  let(:existing_visitor_id) { "00000000-0000-0000-0000-000000000000" }
  let(:remote_visitor) do
    {
      id: existing_visitor_id,
      assignments: [
        { split_name: 'blue_button', variant: 'true', unsynced: true },
        { split_name: 'time', variant: 'waits_for_no_man', unsynced: false }
      ]
    }
  end
  let(:split_registry) do
    {
      'blue_button' => {
        'false' => 50,
        'true' => 50
      },
      'quagmire' => {
        'untenable' => 50,
        'manageable' => 50
      },
      'time' => {
        'hammertime' => 100,
        'clobberin_time' => 0
      }
    }
  end

  before do
    allow(TestTrack::Remote::Visitor).to receive(:find).and_call_original
    allow(TestTrack::Remote::Visitor).to receive(:fake_instance_attributes).and_return(remote_visitor)
    allow(TestTrack::Remote::SplitRegistry).to receive(:to_hash).and_return(split_registry)
  end

  it "preserves a passed ID" do
    expect(existing_visitor.id).to eq existing_visitor_id
  end

  it "generates its own UUID otherwise" do
    allow(SecureRandom).to receive(:uuid).and_return("fake uuid")
    expect(new_visitor.id).to eq "fake uuid"
  end

  describe "#unsynced_assignments" do
    it "returns the passed in unsynced assignments" do
      visitor = TestTrack::Visitor.new(assignments:
        [
          double(split_name: 'foo', variant: 'baz', unsynced?: true),
          double(split_name: 'bar', variant: 'buz', unsynced?: false)
        ]
      )

      expect(visitor.unsynced_assignments.count).to eq 1
      expect(visitor.unsynced_assignments.first.split_name).to eq "foo"
      expect(TestTrack::Remote::Visitor).not_to have_received(:find)
    end

    it "returns the server-provided unsynced assignments for an existing visitor" do
      expect(existing_visitor.unsynced_assignments.count).to eq 1
      expect(existing_visitor.unsynced_assignments.first.split_name).to eq "blue_button"
    end

    it "doesn't get assignments from the server for a newly-generated visitor" do
      expect(new_visitor.unsynced_assignments).to eq([])
      expect(TestTrack::Remote::Visitor).not_to have_received(:find)
    end

    it "returns an empty array if fetching the visitor times out" do
      expect(TestTrack::Remote::Visitor).to receive(:find).with(existing_visitor_id) { raise(Faraday::TimeoutError, "Womp womp") }

      expect(existing_visitor.unsynced_assignments).to eq []
    end
  end

  describe "#assignment_registry" do
    it "return a hash generated from the passed in assignments" do
      visitor = TestTrack::Visitor.new(assignments:
        [
          double(split_name: 'foo', variant: 'baz', unsynced?: false),
          double(split_name: 'bar', variant: 'buz', unsynced?: false)
        ]
      )

      expect(visitor.assignment_registry["foo"].variant).to eq("baz")
      expect(visitor.assignment_registry["bar"].variant).to eq("buz")
      expect(TestTrack::Remote::Visitor).not_to have_received(:find)
    end

    it "doesn't get the assignment registry from the server for a newly-generated visitor" do
      expect(new_visitor.assignment_registry).to eq({})
      expect(TestTrack::Remote::Visitor).not_to have_received(:find)
    end

    it "returns the server-provided assignments for an existing visitor" do
      expect(existing_visitor.assignment_registry['blue_button'].variant).to eq 'true'
      expect(existing_visitor.assignment_registry['time'].variant).to eq 'waits_for_no_man'
    end

    it "returns an empty hash if fetching the visitor times out" do
      allow(TestTrack::Remote::Visitor).to receive(:find) { raise(Faraday::TimeoutError, "Womp womp") }

      expect(existing_visitor.assignment_registry).to eq({})

      expect(TestTrack::Remote::Visitor).to have_received(:find).with(existing_visitor_id)
    end
  end

  describe "#assignment_json" do
    it 'returns a json formatted hash of assignments' do
      expect(existing_visitor.assignment_json).to eq("blue_button" => "true", "time" => "waits_for_no_man")
    end
  end

  describe "#vary" do
    let(:blue_block) { -> { '.blue' } }
    let(:red_block) { -> { '.red' } }
    let(:split_name) { 'quagmire' }

    context "new_visitor" do
      before do
        allow(TestTrack::Assignment).to receive(:new).and_return(instance_double(TestTrack::Assignment,
          split_name: split_name,
          variant: "manageable",
          unsynced?: true))
      end

      def vary_quagmire_split
        new_visitor.vary(split_name.to_sym) do |v|
          v.when :untenable do
            raise "this branch shouldn't be executed, buddy"
          end
          v.default :manageable do
            "#winning"
          end
        end
      end

      it "creates a new assignment" do
        expect(vary_quagmire_split).to eq "#winning"
        expect(TestTrack::Assignment).to have_received(:new).with(new_visitor, split_name)
      end

      it "updates #unsynced_assignments with assignment" do
        expect(vary_quagmire_split).to eq "#winning"
        new_visitor.unsynced_assignments.first.tap do |assignment|
          expect(assignment.split_name).to eq 'quagmire'
          expect(assignment.variant).to eq 'manageable'
        end
      end
    end

    context "existing_visitor" do
      before do
        allow(TestTrack::Assignment).to receive(:new).and_call_original
      end

      def vary_blue_button_split
        existing_visitor.vary :blue_button do |v|
          v.when :true, &blue_block
          v.default :false, &red_block
        end
      end

      def vary_time_split
        existing_visitor.vary :time do |v|
          v.when :clobberin_time do
            "Fantastic Four IV: The Fantasticing"
          end
          v.default :hammertime do
            "can't touch this"
          end
        end
      end

      it "does not create a new Assignment for an already assigned split" do
        expect(vary_blue_button_split).to eq ".blue"
        expect(TestTrack::Assignment).not_to have_received(:new)
      end

      it "creates new assignment for unimplemented previous assignment" do
        expect(existing_visitor.assignment_registry['time'].variant).to eq 'waits_for_no_man'

        expect(vary_time_split).to eq "can't touch this"
        expect(TestTrack::Assignment).not_to have_received(:new)

        expect(existing_visitor.assignment_registry['time'].variant).to eq 'hammertime'
        expect(existing_visitor.assignment_registry['time']).to be_unsynced
      end

      context "when TestTrack server is unavailable" do
        before do
          allow(TestTrack::Remote::Visitor).to receive(:find) { raise(Faraday::TimeoutError, "woopsie") }
        end

        it "doesn't do anything" do
          expect(vary_time_split).to eq "can't touch this"
          expect(existing_visitor.assignment_registry['time'].variant).to eq 'hammertime'
          expect(existing_visitor.assignment_registry['time']).not_to be_unsynced
        end
      end
    end

    context "structure" do
      it "must be given a block" do
        expect { new_visitor.vary(:blue_button) }.to raise_error("must provide block to `vary` for blue_button")
      end

      it "requires less than two defaults" do
        expect do
          new_visitor.vary(:blue_button) do |v|
            v.when :true, &blue_block
            v.default :false, &red_block
            v.default :false, &red_block
          end
        end.to raise_error("cannot provide more than one `default`")
      end

      it "requires more than zero defaults" do
        expect { new_visitor.vary(:blue_button) { |v| v.when(:true, &blue_block) } }.to raise_error("must provide exactly one `default`")
      end

      it "requires at least one when" do
        expect do
          new_visitor.vary(:blue_button) do |v|
            v.default :true, &red_block
          end
        end.to raise_error("must provide at least one `when`")
      end
    end
  end

  describe "#ab" do
    it "leverages vary to configure the split" do
      allow(new_visitor).to receive(:vary).and_call_original
      new_visitor.ab "quagmire", "manageable"
      expect(new_visitor).to have_received(:vary).with("quagmire").exactly(:once)
    end

    context "with an explicit true_variant" do
      it "returns true when assigned to the true_variant" do
        allow(TestTrack::VariantCalculator).to receive(:new).and_return(double(variant: 'manageable'))
        expect(new_visitor.ab("quagmire", "manageable")).to eq true
      end

      it "returns false when not assigned to the true_variant" do
        allow(TestTrack::VariantCalculator).to receive(:new).and_return(double(variant: 'untenable'))
        expect(new_visitor.ab("quagmire", "manageable")).to eq false
      end
    end

    context "with an implicit true_variant" do
      it "returns true when variant is true" do
        allow(TestTrack::VariantCalculator).to receive(:new).and_return(double(variant: 'true'))
        expect(new_visitor.ab("blue_button")).to eq true
      end

      it "returns false when variant is false" do
        allow(TestTrack::VariantCalculator).to receive(:new).and_return(double(variant: 'false'))
        expect(new_visitor.ab("blue_button")).to eq false
      end

      it "returns false when split variants are not true and false" do
        expect(new_visitor.ab("time")).to eq false
      end
    end
  end

  describe "#split_registry" do
    it "memoizes the global SplitRegistry hash" do
      2.times { existing_visitor.split_registry }
      expect(TestTrack::Remote::SplitRegistry).to have_received(:to_hash).exactly(:once)
    end
  end

  describe "#link_identifier!" do
    subject { described_class.new(id: "fake_visitor_id") }
    let(:delayed_identifier_proxy) { double(create!: "fake visitor") }

    before do
      allow(TestTrack::Remote::Identifier).to receive(:delay).and_return(delayed_identifier_proxy)
    end

    it "sends the appropriate params to test track" do
      allow(TestTrack::Remote::Identifier).to receive(:create!).and_call_original
      subject.link_identifier!('bettermentdb_user_id', 444)
      expect(TestTrack::Remote::Identifier).to have_received(:create!).with(
        identifier_type: 'bettermentdb_user_id',
        visitor_id: "fake_visitor_id",
        value: "444"
      )
    end

    it "preserves id if unchanged" do
      subject.link_identifier!('bettermentdb_user_id', 444)
      expect(subject.id).to eq "fake_visitor_id"
    end

    it "delays the identifier creation if TestTrack times out and carries on" do
      allow(TestTrack::Remote::Identifier).to receive(:create!) { raise(Faraday::TimeoutError, "You snooze you lose!") }
      subject.link_identifier!('bettermentdb_user_id', 444)

      expect(subject.id).to eq "fake_visitor_id"

      expect(delayed_identifier_proxy).to have_received(:create!).with(
        identifier_type: 'bettermentdb_user_id',
        visitor_id: "fake_visitor_id",
        value: "444"
      )
    end

    it "normally doesn't delay identifier creation" do
      subject.link_identifier!('bettermentdb_user_id', 444)

      expect(subject.id).to eq "fake_visitor_id"
      expect(delayed_identifier_proxy).not_to have_received(:create!)
    end

    context "with stubbed identifier creation" do
      let(:identifier) do
        TestTrack::Remote::Identifier.new(visitor:
        {
          id: "server_id",
          assignments: [
            { split_name: "foo", variant: "definitely", unsynced: false },
            { split_name: "bar", variant: "occasionally", unsynced: true }
          ]
        })
      end

      before do
        allow(TestTrack::Remote::Identifier).to receive(:create!).and_return(identifier)
      end

      it "changes id if changed" do
        subject.link_identifier!('bettermentdb_user_id', 444)
        expect(subject.id).to eq 'server_id'
      end

      it "ingests a server-provided assignment as non-new" do
        subject.link_identifier!('bettermentdb_user_id', 444)

        subject.assignment_registry['foo'].tap do |assignment|
          expect(assignment.variant).to eq 'definitely'
          expect(assignment).not_to be_unsynced
          expect(assignment).not_to be_new_assignment
        end
      end

      it "preserves a local new assignment with no conflicting server-provided assignment as new" do
        subject.assignment_registry['baz'] = instance_double(TestTrack::Assignment,
          split_name: "baz",
          variant: "never",
          unsynced?: true,
          new_assignment?: true)

        subject.link_identifier!('bettermentdb_user_id', 444)

        subject.assignment_registry['baz'].tap do |assignment|
          expect(assignment.variant).to eq 'never'
          expect(assignment).to be_unsynced
          expect(assignment).to be_new_assignment
        end
      end

      it "removes and overrides a local new assignment with a conflicting server-provided assignment" do
        subject.assignment_registry['foo'] = instance_double(TestTrack::Assignment,
          split_name: "foo",
          variant: "something_else",
          unsynced?: true,
          new_assignment?: true)

        subject.link_identifier!('bettermentdb_user_id', 444)

        subject.assignment_registry['foo'].tap do |assignment|
          expect(assignment.variant).to eq 'definitely'
          expect(assignment).not_to be_unsynced
          expect(assignment).not_to be_new_assignment
        end
      end

      it "overrides a local existing assignment with a conflicting server-provided assignment" do
        subject.assignment_registry['foo'] = instance_double(TestTrack::Assignment,
          split_name: "foo",
          variant: "something_else",
          unsynced?: false,
          new_assignment?: false)

        subject.link_identifier!('bettermentdb_user_id', 444)

        subject.assignment_registry['foo'].tap do |assignment|
          expect(assignment.variant).to eq 'definitely'
          expect(assignment).not_to be_unsynced
          expect(assignment).not_to be_new_assignment
        end
      end

      it "merges server-provided unsynced_assignments into local unsynced_assignments" do
        expect(subject.assignment_registry['blue_button']).to be_unsynced

        subject.link_identifier!('bettermentdb_user_id', 444)

        expect(subject.assignment_registry['blue_button']).to be_unsynced
        expect(subject.assignment_registry['bar']).to be_unsynced
      end
    end
  end

  describe ".backfill_identity" do
    let(:params) { { identifier_type: "clown_id", identifier_value: "1234", existing_mixpanel_id: "ABCDEFG" } }
    let(:create_alias_job) { instance_double(TestTrack::CreateAliasJob, perform: true) }
    let(:remote_visitor) do
      TestTrack::Remote::Visitor.new(
        id: "remote_visitor_id",
        assignments: [
          { split_name: "foo", variant: "bar", unsynced: false }
        ]
      )
    end

    before do
      allow(TestTrack::Remote::Visitor).to receive(:from_identifier).and_return(remote_visitor)
      allow(TestTrack::CreateAliasJob).to receive(:new).and_return(create_alias_job)
    end

    it "returns a new visitor populated with data from the test track server" do
      visitor = described_class.backfill_identity(params)
      expect(visitor.id).to eq "remote_visitor_id"
      expect(visitor.assignment_registry["foo"].variant).to eq("bar")
      expect(TestTrack::Remote::Visitor).to have_received(:from_identifier).with("clown_id", "1234")
    end

    it "performs a CreateAliasJob" do
      described_class.backfill_identity(params)
      expect(TestTrack::CreateAliasJob).to have_received(:new).with(
        existing_mixpanel_id: 'ABCDEFG',
        alias_id: 'remote_visitor_id'
      )
      expect(create_alias_job).to have_received(:perform)
    end
  end
end
