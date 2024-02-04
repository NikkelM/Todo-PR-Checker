FROM ruby:3.2

WORKDIR /app

COPY Gemfile Gemfile.lock ./
ENV BUNDLE_FROZEN=true
RUN gem install bundler && bundle config set --local without 'test'
RUN bundle install

COPY . ./

CMD ["ruby", "./app.rb"]