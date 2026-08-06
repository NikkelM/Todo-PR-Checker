FROM ruby:3.2

WORKDIR /app

ENV APP_ENV=production
ENV RACK_ENV=production

COPY Gemfile Gemfile.lock ./

RUN bundle install

COPY . ./

CMD ["ruby", "./app.rb"]