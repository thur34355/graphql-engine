import * as React from 'react';
import { connect, ConnectedProps } from 'react-redux';
import {
  Analytics,
  REDACT_EVERYTHING,
} from '../../../../../features/Analytics';
import { isCloudConsole } from '../../../../../utils/cloudConsole';
import Globals from '../../../../../Globals';
import { ReduxState } from '../../../../../types';
import styles from './styles.module.scss';
import { mapDispatchToPropsEmpty } from '../../../../Common/utils/reactUtils';
import Tabbed from '../TabbedDataSourceConnection';
import { NotFoundError } from '../../../../Error/PageNotFound';
import { getDataSources } from '../../../../../metadata/selector';
import { Neon } from './Neon';

type Props = InjectedProps;

const CreateDataSource: React.FC<Props> = ({ dispatch, allDataSources }) => {
  // this condition fails for everything other than a Hasura Cloud project
  if (!isCloudConsole(Globals)) {
    throw new NotFoundError();
  }

  return (
    <Tabbed tabName="create">
      <Analytics name="CreateDataSource" {...REDACT_EVERYTHING}>
        <div className={styles.connect_db_content}>
          <div className={`${styles.container} mb-md`}>
            <div className="w-full mb-md">
              <Neon
                allDatabases={allDataSources.map(d => d.name)}
                dispatch={dispatch}
              />
            </div>
          </div>
        </div>
      </Analytics>
    </Tabbed>
  );
};

const mapStateToProps = (state: ReduxState) => {
  return {
    currentDataSource: state.tables.currentDataSource,
    currentSchema: state.tables.currentSchema,
    allDataSources: getDataSources(state),
  };
};

const connector = connect(mapStateToProps, mapDispatchToPropsEmpty);
type InjectedProps = ConnectedProps<typeof connector>;
const ConnectedCreateDataSourcePage = connector(CreateDataSource);
export default ConnectedCreateDataSourcePage;
