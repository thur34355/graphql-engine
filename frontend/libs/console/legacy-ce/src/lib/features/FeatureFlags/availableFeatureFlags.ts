import { FeatureFlagDefinition } from './types';

const relationshipTabTablesId = 'f6c57c31-abd3-46d9-aae9-b97435793273';
const importActionFromOpenApiId = '12e5aaf4-c794-4b8f-b762-5fda0bff946a';
const enabledNewUIForBigQuery = 'e2d790ba-96fb-11ed-a8fc-0242ac120002';

export const availableFeatureFlagIds = {
  relationshipTabTablesId,
  importActionFromOpenApiId,
  enabledNewUIForBigQuery,
};

export const availableFeatureFlags: FeatureFlagDefinition[] = [
  {
    id: relationshipTabTablesId,
    title: 'New Relationship tab UI for tables/views',
    description:
      'Use the new UI for the Relationship tab of Tables/Views in Data section.',
    section: 'data',
    status: 'release candidate',
    defaultValue: true,
    discussionUrl: '',
  },
  {
    id: enabledNewUIForBigQuery,
    title: 'Enable the revamped UI for BigQuery',
    description: 'Try out the new UI experience for BigQuery.',
    section: 'data',
    status: 'experimental',
    defaultValue: false,
    discussionUrl: '',
  },
];
