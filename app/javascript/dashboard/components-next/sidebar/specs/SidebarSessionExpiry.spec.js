import { mount, flushPromises } from '@vue/test-utils';
import { computed, ref } from 'vue';
import Sidebar from '../Sidebar.vue';
import TeamsAPI from 'dashboard/api/teams';
import { actions as teamActions } from 'dashboard/store/modules/teams/actions';

const mocks = vi.hoisted(() => ({ dispatch: null, commit: vi.fn() }));
vi.mock('vuex', async importOriginal => ({
  ...(await importOriginal()),
  useStore: () => ({ dispatch: mocks.dispatch }),
}));
vi.mock('dashboard/api/teams', () => ({ default: { get: vi.fn() } }));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    accountScopedRoute: name => ({ name }),
    isOnChatwootCloud: ref(false),
  }),
}));
vi.mock('dashboard/composables/useConfig', () => ({
  useConfig: () => ({ isEnterprise: false }),
}));
vi.mock('dashboard/composables/utils/useKbd', () => ({ useKbd: () => '' }));
vi.mock('../useSidebarKeyboardShortcuts', () => ({
  useSidebarKeyboardShortcuts: () => {},
}));
vi.mock('../provider', () => ({
  provideSidebarContext: () => {},
  useSidebarResize: () => ({
    sidebarWidth: ref(200),
    isCollapsed: ref(false),
    setSidebarWidth: () => {},
    saveWidth: () => {},
    snapToCollapsed: () => {},
    snapToExpanded: () => {},
    COLLAPSED_THRESHOLD: 80,
  }),
}));
vi.mock('dashboard/composables/store', async importOriginal => ({
  ...(await importOriginal()),
  useMapGetter: key =>
    computed(() => {
      if (['getCurrentAccountId', 'getCurrentUserID'].includes(key)) return 1;
      if (key === 'accounts/isFeatureEnabledonAccount') return () => false;
      return [];
    }),
}));

describe('Sidebar background team loading', () => {
  it.each([401, 503])(
    'handles a pending background team request failing with %s',
    async status => {
      const unhandled = [];
      const onUnhandled = error => unhandled.push(error.message);
      process.on('unhandledRejection', onUnhandled);
      let rejectRequest;
      TeamsAPI.get.mockImplementation(
        () =>
          new Promise((_, reject) => {
            rejectRequest = reject;
          })
      );
      mocks.dispatch = type =>
        type === 'teams/get'
          ? teamActions.get({ commit: mocks.commit })
          : Promise.resolve();
      // Exercise the real setup/mounted lifecycle without rendering unrelated menus.
      const wrapper = mount({ ...Sidebar, render: () => null });
      try {
        expect(TeamsAPI.get).toHaveBeenCalledWith(true);
        const error = new Error(`Request failed with status code ${status}`);
        error.response = { status };
        rejectRequest(error);
        await flushPromises();
        await new Promise(resolve => {
          setTimeout(resolve, 0);
        });
        expect(mocks.commit).toHaveBeenLastCalledWith('SET_TEAM_UI_FLAG', {
          isFetching: false,
        });
        expect(unhandled).toEqual([]);
      } finally {
        wrapper.unmount();
        process.removeListener('unhandledRejection', onUnhandled);
      }
    }
  );
});
