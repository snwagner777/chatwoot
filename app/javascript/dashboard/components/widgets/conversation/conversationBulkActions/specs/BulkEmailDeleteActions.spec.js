import { shallowMount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import BulkEmailDeleteActions from '../BulkEmailDeleteActions.vue';
import BulkActionsAPI from 'dashboard/api/bulkActions';

vi.mock('dashboard/api/bulkActions', () => ({
  default: { deleteEmailConversations: vi.fn() },
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));

const DialogStub = {
  props: [
    'disableConfirmButton',
    'isLoading',
    'title',
    'description',
    'confirmButtonLabel',
  ],
  methods: { open: vi.fn(), close: vi.fn() },
  template: '<div><slot /></div>',
};

describe('BulkEmailDeleteActions', () => {
  let wrapper;
  let store;

  beforeEach(() => {
    store = createStore({
      getters: {
        getCurrentRole: () => 'administrator',
        getInbox: () => id =>
          id === 3 ? { channel_type: 'Channel::Email' } : undefined,
      },
      actions: {
        'bulkActions/removeSelectedConversationIds': vi.fn(),
        'conversationStats/get': vi.fn(),
      },
      mutations: { DELETE_CONVERSATION: vi.fn() },
    });
    wrapper = shallowMount(BulkEmailDeleteActions, {
      props: { conversationIds: [1, 2], inboxIds: [3] },
      global: { plugins: [store], stubs: { Dialog: DialogStub } },
    });
  });

  it('does not offer irreversible purge', () => {
    expect(wrapper.find('input[value="permanent"]').exists()).toBe(false);
  });

  it('freezes the reviewed selection when opening the confirmation', async () => {
    BulkActionsAPI.deleteEmailConversations.mockResolvedValue({
      data: {
        results: [
          { id: 1, deleted: true },
          { id: 2, deleted: true },
        ],
      },
    });
    wrapper.findAllComponents({ name: 'Button' })[0].vm.$emit('click');
    await wrapper.setProps({ conversationIds: [8], inboxIds: [3] });
    wrapper.findComponent(DialogStub).vm.$emit('confirm');
    await flushPromises();
    expect(BulkActionsAPI.deleteEmailConversations).toHaveBeenCalledWith(
      expect.objectContaining({ ids: [1, 2], mode: 'trash' })
    );
  });

  it('fails closed for an unresolved inbox rather than throwing', async () => {
    await wrapper.setProps({ inboxIds: [99] });
    expect(wrapper.findAllComponents({ name: 'Button' })).toHaveLength(0);
  });
  it('retries only failed items using the same request ID', async () => {
    BulkActionsAPI.deleteEmailConversations
      .mockResolvedValueOnce({
        data: {
          results: [
            { id: 1, deleted: true },
            { id: 2, error: 'Provider unavailable' },
          ],
        },
      })
      .mockResolvedValueOnce({ data: { results: [{ id: 2, deleted: true }] } });
    wrapper.findAllComponents({ name: 'Button' })[0].vm.$emit('click');
    wrapper.findComponent(DialogStub).vm.$emit('confirm');
    await flushPromises();
    const first = BulkActionsAPI.deleteEmailConversations.mock.calls[0][0];
    expect(wrapper.text()).toContain('Provider unavailable');
    wrapper.findComponent(DialogStub).vm.$emit('confirm');
    await flushPromises();
    expect(BulkActionsAPI.deleteEmailConversations.mock.calls[1][0]).toEqual({
      ids: [2],
      mode: 'trash',
      request_id: first.request_id,
    });
  });

  it('does not submit the same confirmation twice while it is pending', async () => {
    let complete;
    BulkActionsAPI.deleteEmailConversations.mockImplementation(
      () =>
        new Promise(resolve => {
          complete = resolve;
        })
    );
    wrapper.findAllComponents({ name: 'Button' })[0].vm.$emit('click');
    wrapper.findComponent(DialogStub).vm.$emit('confirm');
    wrapper.findComponent(DialogStub).vm.$emit('confirm');
    await flushPromises();
    expect(BulkActionsAPI.deleteEmailConversations).toHaveBeenCalledTimes(1);
    complete({
      data: {
        results: [
          { id: 1, deleted: true },
          { id: 2, deleted: true },
        ],
      },
    });
    await flushPromises();
  });

  it('does not report a missing result as success', async () => {
    BulkActionsAPI.deleteEmailConversations.mockResolvedValue({
      data: { results: [] },
    });
    wrapper.findAllComponents({ name: 'Button' })[0].vm.$emit('click');
    wrapper.findComponent(DialogStub).vm.$emit('confirm');
    await flushPromises();
    expect(wrapper.text()).toContain('BULK_ACTION.EMAIL_DELETE.UNCONFIRMED');
  });
});
