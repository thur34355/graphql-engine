import React from 'react';
import * as Tabs from '@radix-ui/react-tabs';
import { useTables } from './hooks/useTables';

import { TableList } from './components/TableList';
import Skeleton from 'react-loading-skeleton';
import { TrackableTable } from './types';

const classNames = {
  selected:
    'border-yellow-500 text-yellow-500 whitespace-nowrap p-xs border-b-2 font-semibold -mb-0.5',
  unselected:
    'border-transparent text-muted whitespace-nowrap p-xs border-b-2 font-semibold -mb-0.5 hover:border-gray-300 hover:text-gray-900',
};

interface Props {
  dataSourceName: string;
}

const groupTables = (tables: TrackableTable[]) => {
  const trackedTables: TrackableTable[] = [];
  const untrackedTables: TrackableTable[] = [];

  if (tables) {
    //doing this in one loop to reduce the overhead for large data sets
    tables.forEach(t => {
      if (t.is_tracked) {
        trackedTables.push(t);
      } else {
        untrackedTables.push(t);
      }
    });
  }

  return { trackedTables, untrackedTables };
};

export const TrackTables = ({ dataSourceName }: Props) => {
  const [tab, setTab] = React.useState<'tracked' | 'untracked'>('untracked');

  const { data, isLoading } = useTables({
    dataSourceName,
  });

  const { trackedTables, untrackedTables } = React.useMemo(
    () => groupTables(data ?? []),
    [data]
  );

  if (isLoading)
    return (
      <div className="px-md">
        <Skeleton count={8} height={25} />
      </div>
    );

  if (!data) return <div className="px-md">Something went wrong</div>;

  return (
    <Tabs.Root
      defaultValue="untracked"
      data-testid="track-tables"
      className="space-y-4"
      onValueChange={value =>
        setTab(value === 'tracked' ? 'tracked' : 'untracked')
      }
    >
      <Tabs.List
        className="border-b border-gray-300 px-4 flex space-x-4"
        aria-label="Tabs"
      >
        <Tabs.Trigger
          value="untracked"
          className={
            tab === 'untracked' ? classNames.selected : classNames.unselected
          }
        >
          Untracked
          <span className="bg-gray-300 ml-1 px-1.5 py-0.5 rounded text-xs">
            {untrackedTables.length}
          </span>
        </Tabs.Trigger>
        <Tabs.Trigger
          value="tracked"
          className={
            tab === 'tracked' ? classNames.selected : classNames.unselected
          }
        >
          Tracked
          <span className="bg-gray-300 ml-1 px-1.5 py-0.5 rounded text-xs">
            {trackedTables.length}
          </span>
        </Tabs.Trigger>
      </Tabs.List>

      <Tabs.Content value="tracked" className="px-md">
        <TableList
          mode={'track'}
          dataSourceName={dataSourceName}
          tables={trackedTables}
        />
      </Tabs.Content>
      <Tabs.Content value="untracked" className="px-md">
        <TableList
          mode={'untrack'}
          dataSourceName={dataSourceName}
          tables={untrackedTables}
        />
      </Tabs.Content>
    </Tabs.Root>
  );
};
