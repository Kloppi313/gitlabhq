import Vue from 'vue';
import VueApollo from 'vue-apollo';
import createDefaultClient from '~/lib/graphql';

Vue.use(VueApollo);

const defaultClient = createDefaultClient({
  Query: {
    files() {
      return [];
    },
  },
});

export default new VueApollo({
  defaultClient,
});
