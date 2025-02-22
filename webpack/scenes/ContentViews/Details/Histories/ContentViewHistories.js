import React, { useState, useCallback } from 'react';
import { useSelector } from 'react-redux';
import { TableVariant, TableText, Thead, Tbody, Tr, Th, Td } from '@patternfly/react-table';
import { Label } from '@patternfly/react-core';
import { translate as __ } from 'foremanReact/common/I18n';
import LongDateTime from 'foremanReact/components/common/dates/LongDateTime';
import { urlBuilder } from 'foremanReact/common/urlHelpers';
import PropTypes from 'prop-types';

import TableWrapper from '../../../../components/Table/TableWrapper';
import { getContentViewHistories } from '../ContentViewDetailActions';
import {
  selectCVHistories,
  selectCVHistoriesStatus,
  selectCVHistoriesError,
} from '../ContentViewDetailSelectors';

const ContentViewHistories = ({ cvId }) => {
  const response = useSelector(state => selectCVHistories(state, cvId));
  const status = useSelector(state => selectCVHistoriesStatus(state, cvId));
  const error = useSelector(state => selectCVHistoriesError(state, cvId));

  const [searchQuery, updateSearchQuery] = useState('');

  const columnHeaders = [
    __('Date'),
    __('Version'),
    __('Status'),
    __('Action'),
    __('Description'),
    __('User'),
  ];

  const taskTypes = {
    publish: 'Actions::Katello::ContentView::Publish',
    promotion: 'Actions::Katello::ContentView::Promote',
    removal: 'Actions::Katello::ContentView::Remove',
    incrementalUpdate: 'Actions::Katello::ContentView::IncrementalUpdates',
    export: 'Actions::Katello::ContentViewVersion::Export',
  };

  const actionText = (history) => {
    const {
      action,
      task,
      environment,
    } = history;

    const taskType = task ? task.label : taskTypes[action];

    if (taskType === taskTypes.removal) {
      return <React.Fragment> Deleted from <Label key="1" color="blue" href={`/lifecycle_environments/${environment.id}`}>{`${environment.name}`}</Label>{}</React.Fragment>;
    } else if (taskType === taskTypes.promotion) {
      return <React.Fragment> Promoted to <Label key="2" color="blue" href={`/lifecycle_environments/${environment.id}`}>{`${environment.name}`}</Label>{}</React.Fragment>;
    } else if (taskType === taskTypes.publish) {
      return ('Published new version');
    } else if (taskType === taskTypes.export) {
      return ('Exported content view');
    } else if (taskType === taskTypes.incrementalUpdate) {
      return ('Incremental update');
    }
    return '';
  };

  const emptyContentTitle = __("You currently don't have any history for this content view.");
  const emptyContentBody = __('History will appear here when the content view is published or promoted.'); // needs link
  const emptySearchTitle = __('No matching history record found');
  const emptySearchBody = __('Try changing your search settings.');
  const { results, ...metadata } = response;

  return (
    <TableWrapper
      {...{
        metadata,
        emptyContentTitle,
        emptyContentBody,
        emptySearchTitle,
        emptySearchBody,
        searchQuery,
        updateSearchQuery,
        error,
        status,
      }}
      variant={TableVariant.compact}
      autocompleteEndpoint={`/content_views/${cvId}/history/auto_complete_search`}
      fetchItems={useCallback(params => getContentViewHistories(cvId, params), [cvId])}
    >
      <Thead>
        <Tr>
          {columnHeaders.map(col =>
            <Th key={col}>{col}</Th>)}
        </Tr>
      </Thead>
      <Tbody>
        {results?.map((history) => {
          const {
            version,
            version_id: versionId,
            created_at: createdAt,
            status: taskStatus,
            description,
            user,
          } = history;
          return (
            <Tr key={`${versionId}_${createdAt}`}>
              <Td key={createdAt}><LongDateTime date={createdAt} showRelativeTimeTooltip /></Td>
              <Td>
                <a href={urlBuilder(`content_views/${cvId}/versions/${versionId}`, '')}>{`Version ${version}`}</a>
              </Td>
              <Td>{taskStatus}</Td>
              <Td>{actionText(history)}</Td>
              <Td><TableText wrapModifier="truncate">{description}</TableText></Td>
              <Td>{user}</Td>
            </Tr>
          );
        })
        }
      </Tbody>
    </TableWrapper>
  );
};
ContentViewHistories.propTypes = {
  cvId: PropTypes.number.isRequired,
};
export default ContentViewHistories;
