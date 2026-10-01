import ApiClient from './ApiClient';

class BulkActionsAPI extends ApiClient {
  constructor() {
    super('bulk_actions', { accountScoped: true });
  }

  deleteEmailConversations(data) {
    return axios.post(
      `${this.baseUrl()}/conversations/bulk_email_delete`,
      data
    );
  }
}

export default new BulkActionsAPI();
